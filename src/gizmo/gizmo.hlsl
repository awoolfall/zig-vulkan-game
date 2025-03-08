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

struct ps_out
{
    float4 colour : SV_TARGET0;
    unsigned int id : SV_TARGET1;
};

ps_out ps_main(vs_out input)
{
    ps_out output = (ps_out) 0;

    output.colour = float4(colour.rgb, 1.0);
    output.id = id;

    return output;
}
