#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

struct PushConstants
{
    float4x4 view_projection_matrix;
    float4 camera_pos;

    float4 origin; // worldspace origin of the terrain. grid position (0, 0).

    int2 terrain_grid_position; // index position of this terrain grid
    float terrain_grid_length; // vertices along each edge of grid square
    float terrain_density_m; // meters between each vertex

    float map_height_scale;
    float map_length_m;
    float2 __pad;

    float4 modify_cells;
    float2 modify_center;
    float modify_radius;
    float modify_strength;
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
Texture2DArray normal_textures;

[[vk::binding(2, 1)]]
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
vs_out vs_main(vs_in input, int instance_id : SV_InstanceID)
{
    vs_out output = (vs_out) 0;
    output.grid_position = float2(instance_id / 64, instance_id % 64) - float2(64 / 2, 64 / 2);
    
    float size = push_constant.terrain_grid_length * push_constant.terrain_density_m;
    float3 pos = push_constant.origin.xyz + input.pos * float3(size, 0.0, size);
    float3 grid_offset = (push_constant.terrain_grid_position.xxy + output.grid_position.xxy) * float3(size, 0.0, size);
    pos += grid_offset;

    float2 heightmap_uv = (pos.xz - push_constant.origin.xz) / push_constant.map_length_m;    
    output.tex_coord = heightmap_uv;

    float height = heightmap_textures.SampleLevel(diffuse_sampler, float3(heightmap_uv, 0.0), 0).r;

    output.world_position = float4(pos, 1.0);
    output.world_position += float4(0.0, height * push_constant.map_height_scale, 0.0, 0.0);
    output.position = mul(output.world_position, push_constant.view_projection_matrix);

    float c = (height + 1.0) / 5.0;
    output.colour = float4(c, c, c, height);

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
    ps_out output = (ps_out) 0;
    output.colour = clamp(abs(float4(input.colour.rgb, 1.0) - 0.2), 0.0, 1.0);

    float3 view_dir = normalize(push_constant.camera_pos.xyz - input.world_position.xyz);
    float roughness = 0.5;

    float3 uv = float3(input.tex_coord, 0.0);
    // float hx0 = heightmap_textures.Sample(diffuse_sampler, uv + float3(-0.005, 0.0, 0.0)).r * push_constant.map_height_scale;
    // float hx1 = heightmap_textures.Sample(diffuse_sampler, uv + float3(+0.005, 0.0, 0.0)).r * push_constant.map_height_scale;
    // float hy0 = heightmap_textures.Sample(diffuse_sampler, uv + float3(0.0, -0.005, 0.0)).r * push_constant.map_height_scale;
    // float hy1 = heightmap_textures.Sample(diffuse_sampler, uv + float3(0.0, +0.005, 0.0)).r * push_constant.map_height_scale;

    // float3 normal = normalize(float3(
    //             (hx0 - hx1) / (0.01 * push_constant.map_length_m),
    //             1.0,
    //             (hy0 - hy1) / (0.01 * push_constant.map_length_m)
    //             ));
    float3 normal = normal_textures.Sample(diffuse_sampler, uv).rbg;
    normal -= float3(0.5, 0.0, 0.5);
    normal = normalize(normal);

    for (int i = 0; i < MAX_LIGHTS; i++) {
        LightData light = lights_data[0].lights[i];

        float3 light_diffuse = calculate_light_diffuse(
                light,
                view_dir,
                input.world_position.xyz,
                normal, // TODO
                roughness
                );

        output.colour.rgb += light_diffuse * output.colour.rgb;
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

    output.tex_coord = input.tex_coord;
    return output;
}

