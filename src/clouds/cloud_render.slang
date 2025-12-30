#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

struct PushConstants
{
    int hi; // unused
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

struct LightsData
{
    LightData lights[MAX_LIGHTS];
};

[[vk::binding(0, 0)]]
ConstantBuffer<LightsData> lights_data : register(b0);

[[vk::binding(1, 0)]]
Texture2D cloud_sample_image;

[[vk::binding(2, 0)]]
SamplerState diffuse_sampler;

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

    float4 occ = cloud_sample_image.SampleLevel(diffuse_sampler, input.tex_coord, 0);

    float3 hdr = occ.rgb;
    float alpha = occ.a;

    // Premultiply alpha
    float3 premul = hdr * alpha;

    output.colour = float4(premul, alpha);

    return output;
}
