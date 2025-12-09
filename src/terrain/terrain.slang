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

    float4 origin; // worldspace origin of the terrain. grid position (0, 0).

    float terrain_grid_length; // vertices along each edge of grid square

    float terrain_length_m;    // meters along the length of heightmap
    float terrain_length_scale;

    float terrain_height_m;
    float terrain_height_scale;

    float clipmap_level;

    // float4 modify_cells;
    // float2 modify_center;
    // float modify_radius;
    // float modify_strength;
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

    output.tex_coord = (output.world_position.xz - push_constant.origin.xz) / (push_constant.terrain_length_m * push_constant.terrain_length_scale);

    // apply heightmap height
    // TODO mip levels need improvement, calculate quad size and compare it to texel size to determine mip level
    float mip_level = log2(length(output.world_position.xyz - push_constant.camera_pos.xyz) / 10.0);
    mip_level = clamp(mip_level, 0.0, 7.0);

    float height = heightmap_textures.SampleLevel(diffuse_sampler, float3(output.tex_coord, 0.0), mip_level).r;
    output.world_position.y = height * push_constant.terrain_height_m * push_constant.terrain_height_scale;

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
    output.colour = clamp(abs(float4(input.colour.rgb, 1.0) - 0.2), 0.0, 1.0);
    output.colour = float4(1.0, 1.0, 1.0, 1.0) * 0.04;

    float3 view_dir = normalize(push_constant.camera_pos.xyz - input.world_position.xyz);
    float roughness = 0.9;

    float3 uv = float3(input.tex_coord, 0.0);

    // Compute normals from the heightmap using central differences instead
    // of sampling a precomputed normal texture. This keeps normals consistent
    // with any runtime height edits.
    float texel = 1.0 / 4097; // one texel in UV-space

    // world-space horizontal spacing per texel (meters)
    float spacing = (push_constant.terrain_length_m * push_constant.terrain_length_scale) / 4097;

    // Sample neighbor heights (convert sampled [0,1] to world meters)
    float hL = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(-texel, 0.0), 0.0)).r * push_constant.terrain_height_m * push_constant.terrain_height_scale;
    float hR = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(+texel, 0.0), 0.0)).r * push_constant.terrain_height_m * push_constant.terrain_height_scale;
    float hU = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(0.0, -texel), 0.0)).r * push_constant.terrain_height_m * push_constant.terrain_height_scale;
    float hD = heightmap_textures.Sample(diffuse_sampler, float3(uv.xy + float2(0.0, +texel), 0.0)).r * push_constant.terrain_height_m * push_constant.terrain_height_scale;

    // central differences -> slopes (rise / run)
    float dx = (hR - hL) / (2.0 * spacing);
    float dz = (hD - hU) / (2.0 * spacing);

    // Build the normal (y-up). Negate dx/dz so higher neighbour on +x points normal towards -x.
    float3 normal = normalize(float3(-dx, 1.0, -dz));

    float4 diffuse_colour = albedo_textures.Sample(diffuse_sampler, float3(uv.xy, 0));

    for (int i = 0; i < MAX_LIGHTS; i++) {
        LightData light = lights_data[0].lights[i];

        float3 light_diffuse = calculate_light_diffuse(
                light,
                view_dir,
                input.world_position.xyz,
                normal,
                roughness
                );

        output.colour.rgb += light_diffuse * diffuse_colour.rgb;
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
    float fog_end = 100.0;
    float fog_begin = 10.0;
    float fog_amount = 1.0 - clamp((fog_end - fog_distance) / (fog_end - fog_begin), 0.0, 1.0);
    output.colour = lerp(output.colour, float4(133.0 / 255.0, 193.0 / 255.0, 233.0 / 255.0, 2.2) * 1/2.2, fog_amount);

    output.tex_coord = input.tex_coord;
    //output.colour.rgb = input.colour.rgb;
    return output;
}

