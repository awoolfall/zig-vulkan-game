#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

#ifndef MAX_CLOUD_VOLUMES
#define MAX_CLOUD_VOLUMES 4
#endif

struct PushConstants
{
    float4x4 inv_view_projection_matrix;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

struct LightsData
{
    LightData sun_light;
};

[[vk::binding(0, 0)]]
ConstantBuffer<LightsData> lights_data : register(b0);

struct CloudVolume
{
    float3 min;
    uint phase_function;
    float3 max;
};

[[vk::binding(1, 0)]]
ConstantBuffer<CloudVolume[MAX_CLOUD_VOLUMES]> volumes_data : register(b0);

[[vk::binding(2, 0)]]
Texture3D camera_lighting_grid_image;

[[vk::binding(3, 0)]]
Texture3D noise_image;

[[vk::binding(4, 0)]]
Texture2D depth_image;

[[vk::binding(5, 0)]]
SamplerState diffuse_sampler;

struct vs_out
{
    float4 position : SV_POSITION;
    float2 tex_coord : TEXCOORD0;
};

[shader("vertex")]
vs_out vs_main(uint vertId: SV_VertexID)
{
    vs_out output = (vs_out)0;

    output.position = full_screen_quad_vert(vertId);
    output.tex_coord = ((output.position.xy + 1.0) * 0.5);

    return output;
}

#define frustum_length 160.0
#define frustum_z_cells 64.0
#define exp_scale 12.5

inline float z_cell_to_depth_m(float z_cell) {

    return exp(z_cell / exp_scale);
    // constexpr float c = 5.0 / 128.0;
    // return c * z_cell * z_cell;
}

inline float depth_m_to_z_uv(float depth_m) {
    return (exp_scale * log(depth_m) / 64.0);
    // constexpr float ci = 128.0 / 5.0;
    // return sqrt(ci * depth_m) / 64.0;
}

float4 read_camera_lighting_grid(float2 uv, float world_depth) {
    //return float4(1.0, 1.0, 1.0, 1.0);
    const float3 cell = float3(uv, depth_m_to_z_uv(world_depth));
    return camera_lighting_grid_image.SampleLevel(diffuse_sampler, cell, 0.0);
}

bool ray_aabb_intersect(float3 ray_origin, float3 ray_dir, float ray_max, float3 box_min, float3 box_max, out float tMin, out float tMax)
{
    float3 invDir = 1.0 / ray_dir;
    float3 t0 = (box_min - ray_origin) * invDir;
    float3 t1 = (box_max - ray_origin) * invDir;

    // Swap t0 and t1 where direction is negative
    float3 tSmaller = min(t0, t1);
    float3 tLarger = max(t0, t1);

    // Find the largest tMin and smallest tMax
    tMin = max(max(tSmaller.x, tSmaller.y), tSmaller.z);
    tMax = min(min(tLarger.x, tLarger.y), tLarger.z);

    tMin = max(0.0, tMin);
    tMax = min(tMax, ray_max);

    // Ray intersects if tMin <= tMax and tMax >= 0
    return tMax >= max(tMin, 0.0);
}

float rayleigh_phase(float cos_theta) {
    return (3.0 / (16.0 * PI)) * (1.0 + cos_theta * cos_theta);
}

struct ps_out
{
    float4 colour : SV_TARGET0;
};

[shader("pixel")]
ps_out ps_main(vs_out input)
{
    ps_out output = (ps_out)0;

    // Calculate normalized device coordinates [-1, 1]
    float2 ndc = (input.tex_coord.xy * 2.0) - 1.0;

    // Reconstruct world space position at near and far plane
    float4 nearPoint = mul(float4(ndc, 1.0, 1.0), push_constant.inv_view_projection_matrix); // Near plane (depth = 0 in Vulkan)
    float4 farPoint = mul(float4(ndc, 0.0, 1.0), push_constant.inv_view_projection_matrix);  // Far plane (depth = 1 in Vulkan)

    // Perspective divide
    nearPoint.xyz /= nearPoint.w;
    farPoint.xyz /= farPoint.w;

    // Calculate ray direction and origin
    float3 rayDir = normalize(farPoint.xyz - nearPoint.xyz);
    float3 origin = nearPoint.xyz;

    // Sample depth
    uint2 depthDim;
    depth_image.GetDimensions(depthDim.x, depthDim.y);
    float opaque_depth = depth_image.Load(uint3(uint2(input.tex_coord.xy * float2(depthDim)), 0)).r;
    float3 depth_world_pos = calculate_depth_frag_in_world_pos(opaque_depth, ndc, push_constant.inv_view_projection_matrix);

    // Project the reconstructed depth point onto the world-space ray to get
    // the distance along the ray where the opaque geometry lies.
    const float opaque_t = max(0.0, length(depth_world_pos - origin));

    // assumes sun light is directional type
    const float3 sun_light_colour = lights_data.sun_light.colour.rgb * lights_data.sun_light.intensity;
    const float3 sun_light_dir = normalize(lights_data.sun_light.direction.xyz);

    const float phase = rayleigh_phase(dot(rayDir, sun_light_dir));

    const float3 cloud_albedo = float3(1.0, 1.0, 1.0);

    // TODO handle multiple volumes
    const float3 cloud_bounding_box_min = volumes_data[0].min; // float3(-1000.0, -20.0, -1000.0);
    const float3 cloud_bounding_box_max = volumes_data[0].max; // float3(1000.0, 0.0, 1000.0);

    // use phase function 0 to indicate a valid volume
    if (volumes_data[0].phase_function == 0) {
        output.colour = float4(0.0, 0.0, 0.0, 0.0);
        return output;
    }

    constexpr float small_march_distance = 0.1;
    constexpr float large_march_distance = 0.1;

    float tdensity = 0.0;
    float3 col = float3(0.0, 0.0, 0.0);

    const float density = 0.01;

    float tt = 0.0;

    constexpr float froxel_grid_end = 0.0;//z_cell_to_depth_m(64);

    constexpr float absorption = 0.5;
    constexpr float scattering = 0.5;
    constexpr float extinction = absorption + scattering;

    float aabb_intersection_start;
    float aabb_intersection_end;
    if (!ray_aabb_intersect(origin, rayDir, opaque_t, cloud_bounding_box_min, cloud_bounding_box_max, aabb_intersection_start, aabb_intersection_end)) {
        output.colour = float4(0.0, 0.0, 0.0, 0.0);
        return output;
    }

#if 0
    if (aabb_intersection_start < froxel_grid_end) {
        const int start_i = clamp(int(ceil(depth_m_to_z_uv(aabb_intersection_start) * 64.0)), 0, 64);
        const float end_stt = min(z_cell_to_depth_m(start_i), aabb_intersection_end);

        // output.colour = float4(float3(max(end_stt - tt, 0.0)), 0.5);
        // return output;

        const float3 stt_lighting = read_camera_lighting_grid(input.tex_coord, lerp(aabb_intersection_start, end_stt, 0.5)).rgb;
        const float entrance_depth = end_stt - aabb_intersection_start;
        tdensity += density;
        col += (exp(-tt * tdensity)) * stt_lighting;

        tt = end_stt;

        // output.colour = float4(float3(float(start_i) / 64.0), 0.5);
        // return output;

        // frustum grid based lighting step
        constexpr int cell_oversample = 1;
        const int end_i = clamp(int(floor(depth_m_to_z_uv(aabb_intersection_end) * 64.0)), 0, 64);
        for (int i = start_i; i <= end_i; i++) {
            const float gt = z_cell_to_depth_m(float(i));
            const float step_dist = gt - tt;
            const float3 pos = origin + rayDir * gt;

            tdensity += density;
            const float3 lighting = camera_lighting_grid_image.SampleLevel(diffuse_sampler, float3(input.tex_coord, float(i) / 64.0), 0.0).rgb;

            // Accumulate in-scattered light (additive) weighted by transmittance and step
            tt = gt;
            col += (exp(-tt * tdensity)) * lighting;
        }

        float start_ett = tt;
        float exit_distance = min(aabb_intersection_end, froxel_grid_end) - start_ett;
        // output.colour.rgb = float3(tt - start_ett);
        // return output;

        const float3 ett_lighting = read_camera_lighting_grid(input.tex_coord, lerp(start_ett, aabb_intersection_end, 0.5)).rgb;
        tdensity += density;
        col += (exp(-tt * tdensity)) * ett_lighting;

        aabb_intersection_start = start_ett + exit_distance;
    }
#endif

#if 1
    aabb_intersection_start = max(froxel_grid_end, aabb_intersection_start);
    //if (aabb_intersection_start >= froxel_grid_end) {
        tt = aabb_intersection_start;
        const float max_march_distance = min(aabb_intersection_end, 1000.0);

        // raymarch step
        int c = 0;
        while (tt < max_march_distance) {
            const float step_distance = small_march_distance;// * ((tt * tt) / (froxel_grid_end * froxel_grid_end));
            tt += step_distance;
            float3 pos = origin + rayDir * tt;

            float light_aabb_start;
            float light_aabb_end;
            if (!ray_aabb_intersect(pos, sun_light_dir, 100.0, cloud_bounding_box_min, cloud_bounding_box_max, light_aabb_start, light_aabb_end)) {
                continue;
            }

            // Advance optical depth along the ray
            float local_density = noise_image.Sample(diffuse_sampler, (pos / 20.0) % float3(1.0)).r;
            tdensity += local_density * 0.01;

            float ldensity = 0.0;
            float lt = 0.0;
            for (lt = 0.0; lt < light_aabb_end; lt += step_distance) {
                const float3 lpos = pos + sun_light_dir * lt;
                // sample density at lpos (constant here)
                float llocal_density = noise_image.Sample(diffuse_sampler, (lpos / 20.0) % float3(1.0)).r;
                ldensity += density;
            }

            const float3 lighting = sun_light_colour * (exp(-(light_aabb_end - light_aabb_start) * ldensity * extinction));

            // Accumulate in-scattered light (additive) weighted by transmittance and step
            float alpha = exp(-(tt - aabb_intersection_start) * tdensity * extinction);
            col += alpha * lighting * scattering * phase;
            c += 1;
        }
    //}
#endif

    float alpha = 1.0 - exp(-(aabb_intersection_end - aabb_intersection_start) * tdensity * extinction);
    output.colour = float4(col * alpha, alpha);

    return output;
}
