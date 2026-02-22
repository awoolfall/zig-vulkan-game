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

    float3 origin; // worldspace origin of the terrain. grid position (0, 0).

    float terrain_grid_length; // vertices along each edge of grid square

    float terrain_length_scale;
    float terrain_height_scale;

    // float4 modify_cells;
    // float2 modify_center;
    // float modify_radius;
    // float modify_strength;

    float2 clipmap_translation;
    uint32_t clipmap_packed_data;
}

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

[[vk::binding(0, 1)]]
Texture2DArray heightmap_textures;

[[vk::binding(1, 1)]]
Texture2DArray albedo_textures;

[[vk::binding(2, 1)]]
SamplerState diffuse_sampler;

struct vs_out
{
    float4 position : SV_POSITION;
    float4 world_position : WORLD_POS;
    nointerpolation float4 colour : COLOR;
    float2 tex_coord : TEXCOORD0;
    float2 grid_position : TEXCOORD1;
};

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

    output.tex_coord = (output.world_position.xz - push_constant.origin.xz) / (push_constant.terrain_length_scale);

    // apply heightmap height
    // TODO mip levels need improvement, calculate quad size and compare it to texel size to determine mip level
    float mip_level = log2(length(output.world_position.xyz - push_constant.camera_pos.xyz) / 10.0);
    mip_level = clamp(mip_level, 0.0, 7.0);

    float height = heightmap_textures.SampleLevel(diffuse_sampler, float3(output.tex_coord, 0.0), mip_level).r;
    output.world_position.y = height * push_constant.terrain_height_scale;

    output.world_position.y += push_constant.origin.y;

    output.position = mul(output.world_position, push_constant.view_projection_matrix);

    float c = mip_level / 7.0;
    if (floor(mip_level % 3) == 0) {
        output.colour = float4(1.0, 0.0, 0.0, 1.0);
    } else if (floor(mip_level % 3) == 1) {
        output.colour = float4(0.0, 1.0, 0.0, 1.0);
    } else {
        output.colour = float4(0.0, 0.0, 1.0, 1.0);
    }

    float cc = height * height * height * height;
    output.colour.rgb = float3(cc, cc, cc);

    float2 gg = floor((output.tex_coord * pow(2, 12.0 - mip_level)) % 2);
    float g = (gg.x != gg.y) ? 1 : 0;
    output.colour.rgb = float3(g, g, g);

    return output;
}

struct ps_out
{
    float4 colour : SV_TARGET0;
    float2 tex_coord : SV_TARGET1;
};

[shader("pixel")]
ps_out ps_main(vs_out input)
{
    if (input.tex_coord.x < 0.0 || input.tex_coord.y < 0.0) {
        discard;
    }
    if (input.tex_coord.x > 1.0 || input.tex_coord.y > 1.0) {
        discard;
    }

    ps_out output = (ps_out) 0;
    //output.colour = clamp(abs(float4(input.colour.rgb, 1.0) - 0.2), 0.0, 1.0);
    //output.colour = float4(1.0, 1.0, 1.0, 1.0) * 0.04;

    float3 view_dir = normalize(push_constant.camera_pos.xyz - input.world_position.xyz);
    float roughness = 0.9;

    float3 uv = float3(input.tex_coord, 0.0);

    // Compute normals from the heightmap using central differences instead
    // of sampling a precomputed normal texture. This keeps normals consistent
    // with any runtime height edits.
    float texel = 1.0 / 4097; // one texel in UV-space

    // world-space horizontal spacing per texel (meters)
    float spacing = (push_constant.terrain_length_scale) / 4097;

    // Sample neighbor heights (convert sampled [0,1] to world meters)
    float hL = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(-texel, 0.0), 0.0)).r * push_constant.terrain_height_scale;
    float hR = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(+texel, 0.0), 0.0)).r * push_constant.terrain_height_scale;
    float hU = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(0.0, -texel), 0.0)).r * push_constant.terrain_height_scale;
    float hD = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(0.0, +texel), 0.0)).r * push_constant.terrain_height_scale;

    // central differences -> slopes (rise / run)
    float dx = (hR - hL) / (2.0 * spacing);
    float dz = (hD - hU) / (2.0 * spacing);

    // Build the normal (y-up). Negate dx/dz so higher neighbour on +x points normal towards -x.
    float3 normal = normalize(float3(-dx, 1.0, -dz));

    float4 diffuse_colour = albedo_textures.Sample(diffuse_sampler, float3(uv.xy, 0));

    for (int i = 0; i < MAX_LIGHTS; i++) {
        LightData light = lights_data[0].lights[i];
        output.colour.rgb += calculate_light_contribution(light, diffuse_colour.rgb, view_dir, input.world_position.xyz, normal, 0.0, 0.9);
    }
    //output.colour = float4(normal.rgb, 1.0);

    // TODO fix
    // if (
    //     input.tex_coord.x > push_constant.modify_cells.x && input.tex_coord.x < push_constant.modify_cells.y && 
    //     input.tex_coord.y > push_constant.modify_cells.z && input.tex_coord.y < push_constant.modify_cells.w
    // ) {
    //     float modify_radius_uv = push_constant.modify_radius / (push_constant.grid_length * push_constant.grid_scale);
    //     float strength = clamp(1.0 - (length(input.tex_coord - push_constant.modify_center) / modify_radius_uv), 0.0, 1.0);
    //     output.colour += float4(strength, 0.0, 0.0, 0.0);
    // }

    float fog_distance = (0.3 / input.position.w);
    float fog_end = 300.0;
    float fog_begin = 10.0;
    float fog_amount = 1.0 - clamp((fog_end - fog_distance) / (fog_end - fog_begin), 0.0, 1.0);
    float3 fog_colour = pow(float3(133.0 / 255.0, 193.0 / 255.0, 233.0 / 255.0), 2.2);
    output.colour = lerp(output.colour, float4(fog_colour, 1.0), fog_amount);

    output.tex_coord = input.tex_coord;
    //output.colour.rgb = input.colour.rgb;
    return output;
}

