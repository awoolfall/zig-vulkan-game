#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

#ifndef CLIPMAP_QUAD_COUNT
#define CLIPMAP_QUAD_COUNT 128
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

[[vk::binding(1, 0)]]
Texture2D heightmap_slope_texture;

[[vk::binding(2, 0)]]
Texture2D displacement_texture;

[[vk::binding(3, 0)]]
SamplerState diffuse_sampler;

struct vs_out
{
    float4 position : SV_POSITION;
    float4 world_position : WORLD_POS;
    float4 colour : COLOR;
    float2 tex_coord : TEXCOORD0;
    float2 grid_position : TEXCOORD1;
};

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

    output.tex_coord = output.world_position.xz / push_constant.map_length_m;

    const float facet_size = push_constant.map_length_m / push_constant.spectrum_image_size;

    float height = heightmap_slope_texture.SampleLevel(diffuse_sampler, output.tex_coord, 0.0).r;
    output.world_position.y = -5.0 + height * push_constant.map_height_scale;

    float2 displacement = displacement_texture.SampleLevel(diffuse_sampler, output.tex_coord, 0.0).rg;
    output.world_position.xz -= displacement;

    output.position = mul(output.world_position, push_constant.view_projection_matrix);

    float cc = height;
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
    output.colour = clamp(abs(float4(input.colour.rgb, 1.0) - 0.2), 0.0, 1.0);
    output.colour = float4(1.0, 1.0, 1.0, 1.0) * 0.01;

    float3 view_dir = normalize(push_constant.camera_pos.xyz - input.world_position.xyz);
    float roughness = 0.0;

    const float facet_size = push_constant.map_length_m / push_constant.spectrum_image_size;

    float3 normal = float3(0.0, 1.0, 0.0);
    normal.xz = -heightmap_slope_texture.Sample(diffuse_sampler, input.tex_coord).gb;
    normal = normalize(normal);

    float4 deep_colour = float4(pow(float3(46.0 / 255.0, 157.0 / 255.0, 209.0 / 255.0), 2.2), 1.0);
    float4 shallow_colour = float4(pow(float3(88.0 / 255.0, 176.0 / 255.0, 218.0 / 255.0), 2.2), 0.8);

    float4 diffuse_colour = float4(0.05, 0.412, 0.58, 1.0);// lerp(deep_colour, shallow_colour, smoothstep(0.0, 4.0, input.colour.r));// float4(0.1, 0.1, 1.0, 1.0);// float4(saturate((input.colour.rgb + 1.0) / 2.0), 1.0);

    //output.colour = float4(normal.rgb, 1.0);

    // output.colour = float4(input.tex_coord, 0.0, 1.0);

    //output.colour.rgb = normal;

    // Foam Jacobian-based convergence mask
    const float texel = 1.0 / push_constant.spectrum_image_size;
    //const float facet_size = push_constant.map_length_m / push_constant.spectrum_image_size; // metres per texel

    float2 D = displacement_texture.Sample(diffuse_sampler, input.tex_coord).rg; // horizontal displacement in metres
    float2 Dpx = displacement_texture.Sample(diffuse_sampler, input.tex_coord + float2(texel, 0)).rg;
    float2 Dmx = displacement_texture.Sample(diffuse_sampler, input.tex_coord - float2(texel, 0)).rg;
    float2 Dpy = displacement_texture.Sample(diffuse_sampler, input.tex_coord + float2(0, texel)).rg;
    float2 Dmy = displacement_texture.Sample(diffuse_sampler, input.tex_coord - float2(0, texel)).rg;

    float dx_x = (-Dpx.x + Dmx.x) / (2.0 * facet_size);
    float dx_z = (-Dpy.x + Dmy.x) / (2.0 * facet_size);
    float dz_x = (-Dpx.y + Dmx.y) / (2.0 * facet_size);
    float dz_z = (-Dpy.y + Dmy.y) / (2.0 * facet_size);

    float detJ = (1.0 + dx_x) * (1.0 + dz_z) - dx_z * dz_x;
    float conv = max(0.0, 1.0 - detJ); // positive when compressed/converging

    // Height mask to bias foam to crests
    float height = heightmap_slope_texture.Sample(diffuse_sampler, input.tex_coord).r;

    // Tunable parameters (can be promoted to push constants later)
    const float foam_th0 = 0.25;
    const float foam_th1 = 0.7;
    const float height_th0 = 0.0;
    const float height_th1 = 1.0;
    const float foam_strength = 1.5;

    float foam_conv = smoothstep(foam_th0, foam_th1, conv);
    float foam_height = smoothstep(height_th0, height_th1, height);
    float foam_mask = foam_conv;// * foam_height;

    // Blend white foam additively into the lit colour
    diffuse_colour.rgb = saturate(diffuse_colour.rgb + foam_mask * foam_strength);

    float roughnesss = lerp(0.2, 0.8, foam_mask);

    // apply lights
    for (int i = 0; i < MAX_LIGHTS; i++) {
        LightData light = lights_data[0].lights[i];
        output.colour.rgb += calculate_light_contribution(light, diffuse_colour.rgb, view_dir, input.world_position.xyz, normal, 0.5, roughnesss);
    }

    float fog_distance = (0.3 / input.position.w);
    float fog_end = 300.0;
    float fog_begin = 10.0;
    float fog_amount = 1.0 - clamp((fog_end - fog_distance) / (fog_end - fog_begin), 0.0, 1.0);
    float3 fog_colour = pow(float3(133.0 / 255.0, 193.0 / 255.0, 233.0 / 255.0), 2.2);
    output.colour = lerp(output.colour, float4(fog_colour, 1.0), fog_amount);

    output.colour.a = 1.0;
    return output;
}

