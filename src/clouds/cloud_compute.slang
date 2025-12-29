#include "gfx/common.slang"

#ifndef SAMPLE_GRID_SIZE_X
#define SAMPLE_GRID_SIZE_X 128
#endif

#ifndef SAMPLE_GRID_SIZE_Y
#define SAMPLE_GRID_SIZE_Y 128
#endif

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

[[vk::binding(0, 0)]]
[[vk::image_format("rgba32f")]]
RWTexture2D<float4> out_image;

struct LightsData
{
    LightData lights[MAX_LIGHTS];
};

[[vk::binding(1, 0)]]
ConstantBuffer<LightsData> lights_data : register(b0);

struct PushConstants {
    float4x4 inv_projection_view_matrix;
    float3 camera_position;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    uint2 pixelCoord = dtid.xy;
    uint2 imageDim;
    out_image.GetDimensions(imageDim.x, imageDim.y);

    if (pixelCoord.x >= imageDim.x || pixelCoord.y >= imageDim.y) {
        return;
    }

    // Calculate normalized device coordinates [-1, 1]
    float2 ndc = (float2(pixelCoord) + 0.5) / float2(imageDim);
    ndc = ndc * 2.0 - 1.0;

    // Reconstruct world space position at near and far plane
    float4 nearPoint = mul(float4(ndc, 1.0, 1.0), push_constant.inv_projection_view_matrix); // Near plane (depth = 0 in Vulkan)
    float4 farPoint = mul(float4(ndc, 0.0, 1.0), push_constant.inv_projection_view_matrix);  // Far plane (depth = 1 in Vulkan)

    // Perspective divide
    nearPoint /= nearPoint.w;
    farPoint /= farPoint.w;

    // Calculate ray direction
    float3 rayDir = normalize(farPoint.xyz - nearPoint.xyz);

    float density_accum = 0.0;
    float density_at_point = 0.08 * 0.05;

    int marches = 1024;
    float march_distance = 0.05;
    for (int i = 0; i < marches; i++) {
        float3 pos = push_constant.camera_position + rayDir * march_distance * float(i);
        // if (length(pos.xyz) <= 1.0) {
        if (all(abs(pos.xyz) < 2.0)) {
            density_accum += density_at_point;
        }
    }

    out_image.Store(dtid.xy, float4(float3(density_accum), 0.0));
}
