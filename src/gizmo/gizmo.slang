
struct PushConstants
{
    float4x4 mvp;
    float4 colour;
    uint id;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constants;

struct vs_in
{
    float3 position : POS;
};

struct vs_out
{
    float4 position : SV_POSITION;
};

[shader("vertex")]
vs_out vs_main(vs_in input)
{
    vs_out output = (vs_out) 0;
    
    output.position = mul(float4(input.position, 1.0), push_constants.mvp);

    //output.tex_coord = input.tex_coord;
    //output.tex_coord.y = 1.0 - output.tex_coord.y;

    return output;
}

[shader("pixel")]
float4 ps_colour_main(vs_out input) : SV_TARGET
{
    return float4(push_constants.colour.rgb, 1.0);
}

[shader("pixel")]
uint ps_id_main(vs_out input) : SV_TARGET
{
    return push_constants.id;
}
