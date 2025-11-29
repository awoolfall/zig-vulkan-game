#ifndef SAMPLES_PER_AXIS
#define SAMPLES_PER_AXIS 0
#endif

[[vk::binding(0, 0)]]
Texture2D<float> heightmap : register(t0);

[[vk::binding(1, 0)]]
SamplerState sampler : register(s0);

[[vk::binding(2, 0)]]
RWStructuredBuffer<float> output_samples : register(u0);

[numthreads(8, 8, 1)]
void cs_sample(uint3 dtid : SV_DispatchThreadID)
{
    if (SAMPLES_PER_AXIS == 0) return;

    uint2 dimensions;
    heightmap.GetDimensions(dimensions.x, dimensions.y);

    float interval_x = (float)dimensions.x / (float)SAMPLES_PER_AXIS;
    float interval_y = (float)dimensions.y / (float)SAMPLES_PER_AXIS;

    // Compute floating sample position in texel space (sample center)
    float pos_x = (float)dtid.x * interval_x;
    float pos_y = (float)dtid.y * interval_y;

    // Convert to normalized UVs for texture sampling (texel centers)
    float u = (pos_x + 0.5) / (float)dimensions.x;
    float v = (pos_y + 0.5) / (float)dimensions.y;

    u = clamp(u, 0.0, 1.0);
    v = clamp(v, 0.0, 1.0);

    float height = heightmap.SampleLevel(sampler, float2(u, v), 0.0);

    uint output_index = dtid.y * SAMPLES_PER_AXIS + dtid.x;
    output_samples[output_index] = height;
}
