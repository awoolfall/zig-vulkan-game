#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

#ifndef CLIPMAP_QUAD_COUNT
#define CLIPMAP_QUAD_COUNT 128
#endif

#ifndef MAX_SHALLOW_SPOTS
#define MAX_SHALLOW_SPOTS 4
#endif

#ifndef NUM_OCEAN_LOD_LAYERS
#define NUM_OCEAN_LOD_LAYERS 4
#endif

struct PushConstants
{
    float4x4 view_projection_matrix;
    float4 camera_pos;

    float spectrum_image_size;
    float map_length_m;
    float map_height_scale;
    float _pad0;

    float2 clipmap_translation;
    uint32_t clipmap_packed_data;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

struct vs_in
{
    float3 pos : POS;
};

struct LightsData
{
    LightData lights[MAX_LIGHTS];
};

[[vk::binding(0, 0)]]
ConstantBuffer<LightsData[16 * 16]> lights_data : register(b0);

struct ShallowSpot
{
    float2 point_0;
    float2 point_1;
    float inner_distance;
    float outer_distance;

    float2 __pad0;
};

[[vk::binding(1, 0)]]
ConstantBuffer<ShallowSpot[MAX_SHALLOW_SPOTS]> shallow_spots : register(b1);

[[vk::binding(2, 0)]]
Texture2DArray displacement_textures;

[[vk::binding(3, 0)]]
Texture2DArray slope_jacobian_textures;

[[vk::binding(4, 0)]]
SamplerState diffuse_sampler;

[[vk::binding(5, 0)]]
TextureCube<float4> sky_cubemap;

struct vs_out
{
    float4 position : SV_POSITION;
    float4 world_position : WORLD_POS;
    float4 colour : COLOR;
    float2 tex_coord : TEXCOORD0;
    float2 grid_position : TEXCOORD1;
};

float distance_to_line(float2 pt1, float2 pt2, float2 testPt)
{
    float2 ab = pt2 - pt1;
    float2 ap = testPt - pt1;
    float ab_len2 = dot(ab, ab);
    if (ab_len2 <= 0.0) {
        return length(ap); // degenerate segment
    }
    float t = clamp(dot(ap, ab) / ab_len2, 0.0, 1.0);
    float2 closest = pt1 + ab * t;
    return length(testPt - closest);
}

float calculate_layer_map_length(float layer_0_map_length, float layer) {
    return layer_0_map_length / pow(2.0, layer);
}

float4 clipmap_geometry_to_world_position(float3 input_position, float3 camera_pos, float2 clipmap_translation, uint32_t clipmap_packed_data) {
    const uint32_t clipmap_rotations_90 = (uint32_t)((clipmap_packed_data) & 0xff);
    const uint32_t clipmap_level = (uint32_t)((clipmap_packed_data >> 8) & 0xff);

    const float level_scale = pow(2.0, clipmap_level);

    const float quant_level_scale = pow(2.0, clipmap_level + 1);
    const float3 quantised_camera_position = (floor(camera_pos / quant_level_scale) + 0.5) * quant_level_scale;

    const float clipmap_rotation = (float)(clipmap_rotations_90) * (3.14159265359 / 2.0);
    const float4x4 clipmap_rotation_matrix = float4x4(
        float4(cos(clipmap_rotation), 0.0, sin(clipmap_rotation), 0.0),
        float4(0.0, 1.0, 0.0, 0.0),
        float4(-sin(clipmap_rotation), 0.0, cos(clipmap_rotation), 0.0),
        float4(0.0, 0.0, 0.0, 1.0)
    );

    float4 world_position = mul(float4(input_position.xyz + float3(clipmap_translation.x, 0.0, clipmap_translation.y), 1.0), clipmap_rotation_matrix);
    world_position.xz *= level_scale;
    world_position.xz += quantised_camera_position.xz;

    return world_position;
}

// Fresnel reflectance for an air-water interface (unpolarised, n_water = 1.34).
float fresnel_water(float cos_theta_i) {
    const float n = 1.34;
    float sin2_t = saturate((1.0 / (n * n)) * (1.0 - cos_theta_i * cos_theta_i));
    float cos_t  = sqrt(1.0 - sin2_t);
    float rs = (cos_theta_i - n * cos_t) / (cos_theta_i + n * cos_t);
    float rp = (n * cos_theta_i - cos_t)  / (n * cos_theta_i + cos_t);
    return 0.5 * (rs * rs + rp * rp);
}


[shader("vertex")]
vs_out vs_main(vs_in input)
{
    vs_out output = (vs_out)0;

    output.world_position = clipmap_geometry_to_world_position(
        input.pos, 
        push_constant.camera_pos.xyz, 
        push_constant.clipmap_translation, 
        push_constant.clipmap_packed_data
    );

    float mult_mask = 1.0;
    inline for (int i = 0; i < shallow_spots.getCount(); i++) {
        if (shallow_spots[i].outer_distance == shallow_spots[i].inner_distance) { continue; }
        float dist = distance_to_line(shallow_spots[i].point_0, shallow_spots[i].point_1, output.world_position.xz);
        float mult_mask_i = smoothstep(shallow_spots[i].inner_distance, shallow_spots[i].outer_distance, dist);

        mult_mask = min(mult_mask, mult_mask_i);
    }

    output.tex_coord = output.world_position.xz / push_constant.map_length_m;

    float3 displacement = 0.0;
    const uint32_t clipmap_level = (uint32_t)((push_constant.clipmap_packed_data >> 8) & 0xff);
    for (int i = 0; i < NUM_OCEAN_LOD_LAYERS; i++) {
        float p = pow(2.0, i);
        float2 uv = output.tex_coord * p;
        // mip = clipmap_level (coarser tile → higher mip) + i (each layer doubles frequency)
        float disp_lod = float(clipmap_level) + float(i);
        displacement += displacement_textures.SampleLevel(diffuse_sampler, float3(uv, i), disp_lod).xyz;
    }

    output.world_position.y += -5.0 + displacement.y * push_constant.map_height_scale * mult_mask;
    output.world_position.xz -= displacement.xz * mult_mask;

    output.position = mul(output.world_position, push_constant.view_projection_matrix);

    float cc = mult_mask;
    output.colour.rgb = float3(cc, displacement.y, 0.0);

    return output;
}

struct ps_out
{
    float4 colour : SV_TARGET0;
};

[shader("pixel")]
ps_out ps_main(vs_out input)
{
    ps_out output = (ps_out) 0;

    float3 view_dir = normalize(push_constant.camera_pos.xyz - input.world_position.xyz);
    float roughness = 0.0;

    // accumulate horizontal slope components across LODs, and average
    float3 normal = float3(0.0, 0.0, 0.0);
    float jacobian = 0.0;

    // Compute base derivatives once so the loop can't corrupt them per-iteration
    float2 base_dx = ddx(input.tex_coord);
    float2 base_dy = ddy(input.tex_coord);
    for (int i = 0; i < NUM_OCEAN_LOD_LAYERS; i++) {
        const float facet_size = calculate_layer_map_length(push_constant.map_length_m, i) / push_constant.spectrum_image_size;
        float height_to_horizontal = push_constant.map_height_scale / facet_size;

        float p = pow(2.0, i);
        float2 uv    = input.tex_coord * p;
        float2 uv_dx = base_dx * p;
        float2 uv_dy = base_dy * p;
        float3 sj = slope_jacobian_textures.SampleGrad(diffuse_sampler, float3(uv, i), uv_dx, uv_dy).xyz;
        float3 sjn = (float3(sj.x, 0.0, sj.z) / p) * height_to_horizontal;
        normal += float3(sjn.x, 0.0, sjn.z);
        jacobian += sj.y;
    }

    // average horizontal slope and add the vertical component once
    normal /= float(NUM_OCEAN_LOD_LAYERS);
    normal += float3(0.0, 1.0, 0.0);

    // apply mask/strength then normalize
    normal *= max(input.colour.r, 0.4);
    normal = normalize(normal * float3(-1.0, 1.0, -1.0));

    jacobian /= float(NUM_OCEAN_LOD_LAYERS);
    jacobian += (1.0 - input.colour.r);

    float detJ = jacobian;
    float conv = max(0.0, 1.0 - detJ); // positive when compressed/converging

    // Tunable parameters (maybe can be promoted to push constants later)
    const float foam_th0 = 0.1;
    const float foam_th1 = 0.3;
    const float foam_strength = 1.5;

    float foam_conv = smoothstep(foam_th0, foam_th1, conv);
    float foam_mask = foam_conv;

    // Blend white foam additively into the lit colour
    float4 diffuse_colour = float4(0.05, 0.412, 0.58, 1.0);
    diffuse_colour.rgb = saturate(diffuse_colour.rgb + foam_mask * foam_strength);

    float roughnesss = lerp(0.2, 0.8, foam_mask);

    // Fresnel sky reflection: full unpolarised dielectric (n_water = 1.34)
    float3 reflect_dir = reflect(-view_dir, normal);
    float  VdotN       = saturate(dot(view_dir, normal));
    float  F           = fresnel_water(VdotN);

    // Specular AA: measure how fast the normal varies across pixels and convert to roughness.
    // At grazing angles many wave-normal texels collapse into few screen pixels, so the
    // variance spikes exactly where shimmer is worst.
    float3 dndx = ddx(normal);
    float3 dndy = ddy(normal);
    float  normal_variance    = dot(dndx, dndx) + dot(dndy, dndy);
    float  aa_roughness       = saturate(roughnesss + min(normal_variance * 2.0, 0.8));

    // Secondary boost for pure geometric sensitivity: near VdotN=0 the reflected direction
    // swings far for any normal perturbation, even when variance is low.
    float  grazing_boost      = pow(saturate(1.0 - VdotN), 4.0);
    float  effective_roughness = saturate(aa_roughness + grazing_boost * (1.0 - aa_roughness));

    float3 blurred_dir = normalize(lerp(reflect_dir, normal, effective_roughness * effective_roughness));
    float3 sky_refl    = sky_cubemap.Sample(diffuse_sampler, blurred_dir).rgb;

    // apply lights
    const float3 ambient_colour = float3(1.0, 1.0, 1.0) * 0.01;
    output.colour.rgb = ambient_colour;
    
    for (int i = 0; i < MAX_LIGHTS; i++) {
        LightData light = lights_data[0].lights[i];
        output.colour.rgb += calculate_light_contribution(light, diffuse_colour.rgb, view_dir, input.world_position.xyz, normal, 0.5, roughnesss);
    }

    float k1 = 1.0;
    float k2 = 0.2;
    float k3 = 1.0;
    float ambient_light = 0.1;

    float dotsun = saturate(dot(lights_data[0].lights[0].direction.xyz, normal));
    // output.colour.rgb = float3(dotsun, dotsun, dotsun);
    float wave_height = smoothstep(-2.0, 2.0, input.colour.y); // max(input.colour.y + 1.0, 0.0);
    // output.colour.rgb = pow(0.5 - 0.5 * dotsun, 3) * float3(wave_height, wave_height, wave_height);
    float dotnormal = max(dot(view_dir, normal), 0.0);
    dotnormal *= dotnormal;
    // output.colour.rgb = float3(dotnormal, dotnormal, dotnormal);
    float sunnormal = dot(lights_data[0].lights[0].direction.xyz, float3(0.0, 1.0, 0.0));
    output.colour.rgb = output.colour.rgb + saturate(k1 * pow(0.5 - 0.5 * dotsun, 3) * wave_height + k2 * dotnormal) * k3 * (smoothstep(-0.2, 0.5, sunnormal) + ambient_light) * diffuse_colour.rgb;

    // Fresnel-blend surface lighting with reflected sky (energy-conserving)
    output.colour.rgb = lerp(output.colour.rgb, sky_refl, F);

    output.colour.a = 1.0;
    return output;
}

