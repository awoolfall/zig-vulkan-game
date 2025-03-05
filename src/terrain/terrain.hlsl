cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
}

cbuffer instance_data : register(b1)
{
    float4 origin;
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
    
    float height = heightmap_texture.SampleLevel(diffuse_sampler, input.tex_coord, 0).r;
    output.position = float4(((input.pos + float3(0.5, 0.0, 0.5)) * 15.0) + origin.xyz, 1.0);
    output.position += float4(0.0, height, 0.0, 0.0);
    output.position = mul(output.position, vp);

    output.colour = float4(height, height, height, 1.0);

    //output.tex_coord = input.tex_coord;
    //output.tex_coord.y = 1.0 - output.tex_coord.y;

    return output;
}

float4 ps_main(vs_out input) : SV_TARGET
{
    return input.colour;
}
