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

[[vk::binding(1, 0)]]
Texture2D<float> in_depth;

struct LightsData
{
    LightData lights[MAX_LIGHTS];
};

[[vk::binding(2, 0)]]
ConstantBuffer<LightsData> lights_data : register(b0);

struct PushConstants {
    float4x4 inv_view_matrix;
    float4x4 inv_projection_matrix;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

bool shape_function(float3 pos) {
    return pos.y < -5.0 && pos.y > -15.0;
    //return all(abs(pos) < 2.0);
}

float sample_depth_t(float2 uv, uint2 depthDim, float4x4 inv_view_projection_matrix, float3 origin, float3 rayDir) {
    float2 ndc = (uv * 2.0) - 1.0;

    float opaque_depth = in_depth.Load(uint3(clamp(uint2(uv * float2(depthDim)), uint2(0, 0), depthDim - 1), 0));

    // Reconstruct depth sample into world space
    float4 depth_world = mul(float4(ndc, opaque_depth, 1.0), inv_view_projection_matrix);
    depth_world /= depth_world.w;
    float3 depth_world_pos = depth_world.xyz;
    
    // Project the reconstructed depth point onto the world-space ray to get
    // the distance along the ray where the opaque geometry lies.
    float opaque_t = dot(depth_world_pos - origin, rayDir);
    if (opaque_t < 0.0) opaque_t = 0.0;

    return opaque_t;
}

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

    float2 uv = (float2(pixelCoord) + 0.5) / float2(imageDim);

    // Calculate normalized device coordinates [-1, 1]
    float2 ndc = (uv * 2.0) - 1.0;

    float4x4 inv_view_projection_matrix = mul(push_constant.inv_projection_matrix, push_constant.inv_view_matrix);

    // Reconstruct world space position at near and far plane
    float4 nearPoint = mul(float4(ndc, 1.0, 1.0), inv_view_projection_matrix); // Near plane (depth = 0 in Vulkan)
    float4 farPoint = mul(float4(ndc, 0.0, 1.0), inv_view_projection_matrix);  // Far plane (depth = 1 in Vulkan)

    // Perspective divide
    nearPoint.xyz /= nearPoint.w;
    farPoint.xyz /= farPoint.w;

    // Sample depth
    uint2 depthDim;
    in_depth.GetDimensions(depthDim.x, depthDim.y);
    float opaque_depth = in_depth.Load(uint3(uint2(uv * float2(depthDim)), 0));

    // Reconstruct depth sample into world space
    float4 depth_world = mul(float4(ndc, opaque_depth, 1.0), inv_view_projection_matrix);
    depth_world /= depth_world.w;
    float3 depth_world_pos = depth_world.xyz;

    // Calculate ray direction
    float3 rayDir = normalize(farPoint.xyz - nearPoint.xyz);

    float3 cloud_albedo = float3(1.0, 1.0, 1.0);

    float tdensity = 0.0;
    float3 col = float3(0.0, 0.0, 0.0);

    int marches = 1024;
    float march_distance = 0.05;

    // Use world-space origin on the near plane (reverse-Z handling kept as-is)
    float3 origin = nearPoint.xyz;

    // Project the reconstructed depth point onto the world-space ray to get
    // the distance along the ray where the opaque geometry lies.
    float opaque_t = dot(depth_world_pos - origin, rayDir);
    if (opaque_t < 0.0) opaque_t = 0.0;

    // TODO should probably downsample depth texture here instead of 4 loads
    float2 uv_epsilon = float2(1.0 / imageDim.x, 1.0 / imageDim.y) / 2.0;
    opaque_t = max(
        max(
            sample_depth_t(uv + float2(uv_epsilon.x, uv_epsilon.y), depthDim, inv_view_projection_matrix, origin, rayDir),
            sample_depth_t(uv + float2(-uv_epsilon.x, -uv_epsilon.y), depthDim, inv_view_projection_matrix, origin, rayDir)
        ),
        max(
            sample_depth_t(uv + float2(uv_epsilon.x, -uv_epsilon.y), depthDim, inv_view_projection_matrix, origin, rayDir),
            sample_depth_t(uv + float2(-uv_epsilon.x, uv_epsilon.y), depthDim, inv_view_projection_matrix, origin, rayDir)
        )
    );

    for (int i = 0; i < marches; i++) {
        float t = march_distance * (float(i) + 0.5);
        if (t >= opaque_t) break;

        float3 pos = origin + rayDir * t;
        if (!shape_function(pos)) continue;

        float density = 0.01;

        float3 light_dir;
        float3 light_colour;
        if (!calculate_light(lights_data.lights[0], pos, light_dir, light_colour)) { continue; }

        // Compute approximate optical depth toward the light
        float ldensity = 0.0;
        for (int j = 0; j < marches; j++) {
            float lt = march_distance * (float(j) + 0.5);
            float3 lpos = pos - light_dir * lt;
            if (!shape_function(lpos)) continue;
            // sample density at lpos (constant here)
            ldensity += density * march_distance;
        }

        float lightTrans = exp(-ldensity);
        float3 lum = light_colour * cloud_albedo * (1.0 - lightTrans);

        // Transmittance from camera to this sample
        float sampleTrans = exp(-tdensity);
        // Accumulate in-scattered light (additive) weighted by transmittance and step
        col += lum * sampleTrans * march_distance;

        // Advance optical depth along the ray
        tdensity += density * march_distance;
    }

    float alpha = 1.0 - exp(-tdensity);
    out_image.Store(dtid.xy, float4(col, alpha));
}
