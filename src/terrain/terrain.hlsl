cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
}

cbuffer instance_data : register(b1)
{
    float4 origin;
    float4 size;
}

struct vs_in
{
    float3 pos : POS;
    float2 tex_coord : TEXCOORD0;
};

Texture2D heightmap_texture;
SamplerState diffuse_sampler;

struct vs_out
{
    float4 position : SV_POSITION;
    float4 colour : POS;
    float2 tex_coord : TEXCOORD0;
};

vs_out vs_main(vs_in input)
{

    vs_out output = (vs_out) 0;

    float4x4 vp = mul(view, projection);
    
    input.tex_coord.y = 1.0 - input.tex_coord.y;

    float3 pos = (input.pos + float3(0.5, 0.0, 0.5)) * size.xyz;
    
    float height = heightmap_texture.SampleLevel(diffuse_sampler, input.tex_coord, 0).r;
    output.position = float4(pos + origin.xyz, 1.0);
    output.position += float4(0.0, height, 0.0, 0.0);
    output.position = mul(output.position, vp);

    output.colour = float4(height, height, height, 1.0);

    output.tex_coord = input.tex_coord;
    //output.tex_coord.y = 1.0 - output.tex_coord.y;

    return output;
}

struct ps_out
{
    float4 colour : SV_TARGET0;
    float2 tex_coord : SV_TARGET1;
};

ps_out ps_main(vs_out input)
{
    ps_out output = (ps_out) 0;
    output.colour = clamp(abs(input.colour), 0.0, 1.0);
    output.tex_coord = input.tex_coord;
    return output;
}

