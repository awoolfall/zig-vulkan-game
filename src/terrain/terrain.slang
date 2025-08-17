
struct PushConstants
{
    float4x4 view_projection_matrix;

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
    float2 tex_coord : TEXCOORD0;
};

[[vk::binding(0, 0)]]
Texture2DArray heightmap_textures;

[[vk::binding(1, 0)]]
SamplerState diffuse_sampler;

struct vs_out
{
    float4 position : SV_POSITION;
    float4 colour : POS;
    float2 tex_coord : TEXCOORD0;
};

[shader("vertex")]
vs_out vs_main(vs_in input)
{
    input.tex_coord.y = 1.0 - input.tex_coord.y;
    vs_out output = (vs_out) 0;
    
    float size = push_constant.terrain_grid_length * push_constant.terrain_density_m;
    float3 pos = push_constant.origin.xyz + (input.pos + float3(0.5, 0.0, 0.5)) * float3(size, 0.0, size);
    float3 grid_offset = float3(push_constant.terrain_grid_position.xxy) * float3(size, 0.0, size);
    pos += grid_offset;

    float heightmap_uv_distance_per_terrain_grid = (size / push_constant.map_length_m);
    float2 heightmap_uv_distance_per_terrain_grid_f2 = float2(heightmap_uv_distance_per_terrain_grid, heightmap_uv_distance_per_terrain_grid);
    float2 heightmap_uv = (push_constant.terrain_grid_position.xy * heightmap_uv_distance_per_terrain_grid_f2) + (input.tex_coord * heightmap_uv_distance_per_terrain_grid_f2);
    
    float height = heightmap_textures.SampleLevel(diffuse_sampler, float3(heightmap_uv, 0.0), 0).r;
    output.position = float4(pos, 1.0);
    output.position += float4(0.0, height * push_constant.map_height_scale, 0.0, 0.0);
    output.position = mul(output.position, push_constant.view_projection_matrix);

    float c = (height + 1.0) / 5.0;

    output.colour = float4(c,c,c, 1.0);

    output.tex_coord = heightmap_uv;

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
    output.colour = clamp(abs(input.colour - 0.2), 0.0, 1.0);
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

