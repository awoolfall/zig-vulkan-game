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

struct PushConstants
{
    float4x4 view_projection_matrix;
    float4 camera_pos;

    float spectrum_image_size;
    float map_length_m;
    float map_height_scale;

    float clipmap_level;
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
Texture2D displacement_texture;

[[vk::binding(3, 0)]]
Texture2D slope_jacobian_texture;

[[vk::binding(4, 0)]]
SamplerState diffuse_sampler;

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

[shader("vertex")]
vs_out vs_main(vs_in input)
{
    vs_out output = (vs_out)0;

    float clipmap_scale = pow(2, push_constant.clipmap_level) * 100.0;
    float upper_level_clipmap_scale = pow(2, push_constant.clipmap_level + 1) * 100.0;

    bool is_skirt_vert = input.pos.x > 1.0 || input.pos.x < 0.0 || input.pos.z > 1.0 || input.pos.z < 0.0;

    output.world_position = float4(input.pos.xyz, 1.0);
    output.world_position.xz -= 0.5;
    output.world_position.z *= -1.0;
    output.world_position.xz *= clipmap_scale;

    float quad_scale = (clipmap_scale * 2) / CLIPMAP_QUAD_COUNT;
    float upper_level_quad_scale = (upper_level_clipmap_scale * 2) / CLIPMAP_QUAD_COUNT;

    if (is_skirt_vert) {
        output.world_position.xz += round(push_constant.camera_pos.xz / upper_level_quad_scale) * upper_level_quad_scale;
    } else {
        output.world_position.xz += round(push_constant.camera_pos.xz / quad_scale) * quad_scale;
    }

    float mult_mask = 1.0;
    inline for (int i = 0; i < shallow_spots.getCount(); i++) {
        if (shallow_spots[i].outer_distance == shallow_spots[i].inner_distance) { continue; }
        float dist = distance_to_line(shallow_spots[i].point_0, shallow_spots[i].point_1, output.world_position.xz);
        float mult_mask_i = smoothstep(shallow_spots[i].inner_distance, shallow_spots[i].outer_distance, dist);

        mult_mask = min(mult_mask, mult_mask_i);
    }

    output.tex_coord = output.world_position.xz / push_constant.map_length_m;

    const float facet_size = push_constant.map_length_m / push_constant.spectrum_image_size;

    float3 displacement = displacement_texture.SampleLevel(diffuse_sampler, output.tex_coord, 0.0).xyz;

    output.world_position.y = -5.0 + displacement.y * push_constant.map_height_scale * mult_mask;
    output.world_position.xz -= displacement.xz * mult_mask;

    output.position = mul(output.world_position, push_constant.view_projection_matrix);

    float cc = mult_mask;
    output.colour.rgb = float3(cc, cc, cc);

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

    const float facet_size = push_constant.map_length_m / push_constant.spectrum_image_size;

    float3 slope_jacobian = slope_jacobian_texture.Sample(diffuse_sampler, input.tex_coord).xyz;
    slope_jacobian.xz *= max(input.colour.r, 0.4);
    slope_jacobian.y += (1.0 - input.colour.r);

    float3 normal = float3(-slope_jacobian.x, 1.0, -slope_jacobian.z);
    normal = normalize(normal);

    float detJ = slope_jacobian.y;
    float conv = max(0.0, 1.0 - detJ); // positive when compressed/converging

    // Tunable parameters (maybe can be promoted to push constants later)
    const float foam_th0 = 0.25;
    const float foam_th1 = 0.7;
    const float foam_strength = 1.5;

    float foam_conv = smoothstep(foam_th0, foam_th1, conv);
    float foam_mask = foam_conv;

    // Blend white foam additively into the lit colour
    float4 diffuse_colour = float4(0.05, 0.412, 0.58, 1.0);
    diffuse_colour.rgb = saturate(diffuse_colour.rgb + foam_mask * foam_strength);

    float roughnesss = lerp(0.2, 0.8, foam_mask);

    // apply lights
    const float3 ambient_colour = float3(1.0, 1.0, 1.0) * 0.01;
    output.colour.rgb = ambient_colour;
    
    for (int i = 0; i < MAX_LIGHTS; i++) {
        LightData light = lights_data[0].lights[i];
        output.colour.rgb += calculate_light_contribution(light, diffuse_colour.rgb, view_dir, input.world_position.xyz, normal, 0.5, roughnesss);
    }

    // apply fog
    float fog_distance = (0.3 / input.position.w);
    float fog_end = 300.0;
    float fog_begin = 10.0;
    float fog_amount = 1.0 - clamp((fog_end - fog_distance) / (fog_end - fog_begin), 0.0, 1.0);
    float3 fog_colour = pow(float3(133.0 / 255.0, 193.0 / 255.0, 233.0 / 255.0), 2.2);
    output.colour = lerp(output.colour, float4(fog_colour, 1.0), fog_amount);

    output.colour.a = 1.0;
    return output;
}

