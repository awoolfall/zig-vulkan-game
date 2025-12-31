#include "gfx/common.slang"

struct PushConstants
{
    float foo;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

[[vk::binding(0, 0)]]
Texture2D<uint> outline_sample_image;

struct vs_out
{
    float4 position : SV_POSITION;
    float2 tex_coord : TEXCOORD0;
};

[shader("vertex")]
vs_out vs_main(uint vertId: SV_VertexID)
{
    vs_out output = (vs_out)0;

    output.position = full_screen_quad_vert(vertId);
    output.tex_coord = ((output.position.xy + 1.0) * 0.5);

    return output;
}

struct ps_out
{
    float4 colour : SV_TARGET0;
};

[shader("pixel")]
ps_out ps_main(vs_out input)
{
    ps_out output = (ps_out)0;

    uint2 imageDim;
    outline_sample_image.GetDimensions(imageDim.x, imageDim.y);

    uint id = outline_sample_image.Load(uint3(uint2(input.tex_coord * float2(imageDim)), 0));

    const float3 outline_colour = float3(1.0, 0.3, 0.0);
    output.colour = float4(outline_colour, saturate(float(id)));

    return output;
}
