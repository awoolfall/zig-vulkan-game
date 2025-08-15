
struct PushConstants
{
    float4x4 view_projection_matrix;
    float4 origin;
    float height_scale;
    float grid_length;
    float grid_scale;

    float modify_radius;
    float4 modify_cells;
    float2 modify_center;
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
Texture2D heightmap_texture;

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

    vs_out output = (vs_out) 0;
    
    //input.tex_coord.y = 1.0 - input.tex_coord.y;

    float size = push_constant.grid_length * push_constant.grid_scale;
    float3 pos = (input.pos + float3(0.5, 0.0, 0.5)) * float3(size - push_constant.grid_scale, 0.0, size - push_constant.grid_scale);

    float2 centered_uv = input.tex_coord - float2(0.5, 0.5);
    centered_uv *= 31.0;
    centered_uv /= 32.0;
    centered_uv += float2(0.5, 0.5);
    
    float height = heightmap_texture.SampleLevel(diffuse_sampler, centered_uv, 0).r;
    output.position = float4(pos + push_constant.origin.xyz, 1.0);
    output.position += float4(0.0, height * push_constant.height_scale, 0.0, 0.0);
    output.position = mul(output.position, push_constant.view_projection_matrix);

    float c = (height + 1.0) / 5.0;

    output.colour = float4(c,c,c, 1.0);

    output.tex_coord = input.tex_coord;
    //output.tex_coord.y = 1.0 - output.tex_coord.y;

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
    if (
        input.tex_coord.x > push_constant.modify_cells.x && input.tex_coord.x < push_constant.modify_cells.y && 
        input.tex_coord.y > push_constant.modify_cells.z && input.tex_coord.y < push_constant.modify_cells.w
    ) {
        float modify_radius_uv = push_constant.modify_radius / (push_constant.grid_length * push_constant.grid_scale);
        float strength = clamp(1.0 - (length(input.tex_coord - push_constant.modify_center) / modify_radius_uv), 0.0, 1.0);
        output.colour += float4(strength, 0.0, 0.0, 0.0);
    }
    output.tex_coord = input.tex_coord;
    return output;
}

