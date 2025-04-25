cbuffer camera_data : register(b0)
{
    row_major float4x4 projection;
    row_major float4x4 view;
}

cbuffer instance_data : register(b1)
{
    row_major float4x4 model_matrix;
    float4 colour;
    unsigned int id;
}

struct vs_in
{
    float3 position : POS;
};

struct vs_out
{
    float4 position : SV_POSITION;
};

vs_out vs_main(vs_in input)
{
    vs_out output = (vs_out) 0;

    float4x4 vp = mul(view, projection);
    float4x4 mvp = mul(model_matrix, vp);
    
    output.position = mul(float4(input.position, 1.0), mvp);

    //output.tex_coord = input.tex_coord;
    //output.tex_coord.y = 1.0 - output.tex_coord.y;

    return output;
}

float4 ps_colour_main(vs_out input) : SV_TARGET
{
    return float4(colour.rgb, 1.0);
}

unsigned int ps_id_main(vs_out input) : SV_TARGET
{
    return id;
}
