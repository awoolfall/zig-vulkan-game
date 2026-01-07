#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

[[vk::binding(0, 0)]]
[[vk::image_format("rgba32f")]]
RWTexture3D<float4> out_image;

[[vk::binding(1, 0)]]
Texture2D<float> in_depth;

struct LightsData
{
    LightData lights[MAX_LIGHTS];
};

[[vk::binding(2, 0)]]
ConstantBuffer<LightsData> lights_data : register(b0);

struct PushConstants {
    float4x4 inv_view_projection_matrix;
    uint start_z;
    float offset;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

float sample_depth_t(float opaque_depth, float2 ndc, float4x4 inv_view_projection_matrix, float3 origin, float3 rayDir) {
    // Reconstruct depth sample into world space
    float4 depth_world = mul(float4(ndc, opaque_depth, 1.0), inv_view_projection_matrix);
    depth_world /= depth_world.w;
    float3 depth_world_pos = depth_world.xyz;
    
    // Project the reconstructed depth point onto the world-space ray to get
    // the distance along the ray where the opaque geometry lies.
    float opaque_t = dot(depth_world_pos - origin, rayDir);
    if (opaque_t < 0.0) opaque_t = 0.0;

    return opaque_t;
}

#define frustum_length 160.0
#define frustum_z_cells 64.0
#define exp_scale 12.5

inline float z_cell_to_depth_m(float z_cell) {

    return exp(z_cell / exp_scale);
    // constexpr float c = 5.0 / 128.0;
    // return c * float(z_cell * z_cell);
}

inline float depth_m_to_z_uv(float depth_m) {
    return (exp_scale * log(depth_m) / 64.0);
    // constexpr float ci = 128.0 / 5.0;
    // return sqrt(ci * depth_m) / 64.0;
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
    tMin = max(0.0, max(max(tSmaller.x, tSmaller.y), tSmaller.z));
    tMax = min(ray_max, min(min(tLarger.x, tLarger.y), tLarger.z));

    // Ray intersects if tMin <= tMax and tMax >= 0
    return tMin < ray_max && tMax >= max(tMin, 0.0);
}

[shader("compute")]
[numthreads(8, 8, 8)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    uint3 pixelCoord = dtid.xyz + uint3(0, 0, push_constant.start_z);
    uint3 imageDim;
    out_image.GetDimensions(imageDim.x, imageDim.y, imageDim.z);

    if (pixelCoord.x >= imageDim.x || pixelCoord.y >= imageDim.y) {
        return;
    }

    float2 uv = (float2(pixelCoord.xy)) / float2(imageDim.xy);

    // Calculate normalized device coordinates [-1, 1]
    float2 ndc = (uv * 2.0) - 1.0;

    // Reconstruct world space position at near and far plane
    float4 nearPoint = mul(float4(ndc, 1.0, 1.0), push_constant.inv_view_projection_matrix); // Near plane (depth = 0 in Vulkan)
    float4 farPoint = mul(float4(ndc, 0.0, 1.0), push_constant.inv_view_projection_matrix);  // Far plane (depth = 1 in Vulkan)

    // Perspective divide
    nearPoint.xyz /= nearPoint.w;
    farPoint.xyz /= farPoint.w;

    // Calculate ray direction
    float3 rayDir = normalize(farPoint.xyz - nearPoint.xyz);

    // calculate world position of grid cell
    float depth = z_cell_to_depth_m(float(pixelCoord.z) + push_constant.offset);
    float3 pos = nearPoint.xyz + (rayDir * depth);

    float3 cloud_albedo = float3(1.0, 1.0, 1.0);

    const float3 cloud_bounding_box_min = float3(-1000.0, -20.0, -1000.0);
    const float3 cloud_bounding_box_max = float3(1000.0, 0.0, 1000.0);

    float tdensity = 0.0;
    float3 col = float3(0.0, 0.0, 0.0);

    const float max_march_distance = 1000.0;
    float small_march_distance = 0.1;
    float large_march_distance = 1.0;

    constexpr float density = 0.0001;

    for (int l = 0; l < MAX_LIGHTS; l++) {
        float3 light_dir;
        float3 light_colour;
        if (calculate_light(lights_data.lights[l], pos, light_dir, light_colour)) {
            float dist_point_to_light = length(lights_data.lights[l].position.xyz - pos);
            if (lights_data.lights[l].type == LIGHT_TYPE_SUN || lights_data.lights[l].type == LIGHT_TYPE_DIRECTIONAL) {
                dist_point_to_light = 1000.0;
            }

            float aabb_start_t;
            float aabb_end_t;
            if (!ray_aabb_intersect(pos, -light_dir, dist_point_to_light, cloud_bounding_box_min, cloud_bounding_box_max, aabb_start_t, aabb_end_t)) { continue; }
            
            // Compute approximate optical depth toward the light
            float ldensity = 0.0;
            float lt = 0.0;
            const float max_length = aabb_end_t;
            for (lt = 0.0; lt < max_length; lt += small_march_distance) {
                const float3 lpos = pos - light_dir * lt;
                // sample density at lpos (constant here)
                ldensity += density * small_march_distance;
            }

            float lightTrans = exp(-ldensity);
            float3 lum = light_colour * cloud_albedo * (lightTrans);
            col += lum;
        }
    }

    float alpha = 1.0 - exp(-tdensity);
    float3 old_col = out_image.Load(pixelCoord.xyz).rgb;
    out_image.Store(pixelCoord.xyz, float4((old_col*2.0 + col.rgb) / 3.0, 0.0));
    return;
}
