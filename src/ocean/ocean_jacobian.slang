#ifndef TEX_SIZE
#define TEX_SIZE 1
#endif

[[vk::binding(0, 0)]]
Texture2D<float4> displacement_image : register(t0);

[[vk::binding(1, 0)]]
[[vk::image_format("rgba32f")]]
RWTexture2D<float4> out_slope_jacobian_image;

struct PushConstants {
    float map_length_m;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    float2 D = displacement_image.Load(dtid).xz; // horizontal displacement in metres
    float2 Dpx = displacement_image.Load((dtid + int3(1, 0, 0)) % TEX_SIZE).xz;
    float2 Dmx = displacement_image.Load((dtid - int3(1, 0, 0)) % TEX_SIZE).xz;
    float2 Dpy = displacement_image.Load((dtid + int3(0, 1, 0)) % TEX_SIZE).xz;
    float2 Dmy = displacement_image.Load((dtid - int3(0, 1, 0)) % TEX_SIZE).xz;

    const float facet_size = push_constant.map_length_m / TEX_SIZE;

    float dx_x = (-Dpx.x + Dmx.x) / (2.0 * facet_size);
    float dx_z = (-Dpy.x + Dmy.x) / (2.0 * facet_size);
    float dz_x = (-Dpx.y + Dmx.y) / (2.0 * facet_size);
    float dz_z = (-Dpy.y + Dmy.y) / (2.0 * facet_size);

    float detJ = (1.0 + dx_x) * (1.0 + dz_z) - dx_z * dz_x;

    float4 slope_jacobian = out_slope_jacobian_image.Load(dtid.xy);
    slope_jacobian.y = detJ;
    out_slope_jacobian_image.Store(dtid.xy, slope_jacobian);
}
