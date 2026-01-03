#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

[[vk::binding(0, 0)]]
[[vk::image_format("rgba32f")]]
RWTexture3D<float4> out_image;

[[vk::binding(1, 0)]]
Texture2D<float> in_depth;

struct LightsData
{
    LightData lights[MAX_LIGHTS];
};

[[vk::binding(2, 0)]]
ConstantBuffer<LightsData> lights_data : register(b0);

struct PushConstants {
    float4x4 inv_view_projection_matrix;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

bool shape_function(float3 pos) {
    return pos.y < -5.0 && pos.y > -15.0;
    //return all(abs(pos) < 2.0);
}

float sample_depth_t(float opaque_depth, float2 ndc, float4x4 inv_view_projection_matrix, float3 origin, float3 rayDir) {
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
[numthreads(8, 8, 8)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    uint3 pixelCoord = dtid.xyz;
    uint3 imageDim;
    out_image.GetDimensions(imageDim.x, imageDim.y, imageDim.z);

    if (pixelCoord.x >= imageDim.x || pixelCoord.y >= imageDim.y) {
        return;
    }

    float2 uv = (float2(pixelCoord.xy)) / float2(imageDim.xy);

    // Calculate normalized device coordinates [-1, 1]
    float2 ndc = (uv * 2.0) - 1.0;

    // Reconstruct world space position at near and far plane
    float4 nearPoint = mul(float4(ndc, 1.0, 1.0), push_constant.inv_view_projection_matrix); // Near plane (depth = 0 in Vulkan)
    float4 farPoint = mul(float4(ndc, 0.0, 1.0), push_constant.inv_view_projection_matrix);  // Far plane (depth = 1 in Vulkan)

    // Perspective divide
    nearPoint.xyz /= nearPoint.w;
    farPoint.xyz /= farPoint.w;

    // Calculate ray direction
    float3 rayDir = normalize(farPoint.xyz - nearPoint.xyz);

    // calculate world position of grid cell
    float depth = (5.0 / 128.0) * float(dtid.z) * float(dtid.z);// 160.0 * exp(float(dtid.z) - 64.0);
    float3 pos = nearPoint.xyz + (rayDir * depth);

    float3 cloud_albedo = float3(1.0, 1.0, 1.0);

    float tdensity = 0.0;
    float3 col = float3(0.0);

    const float max_march_distance = 1000.0;
    float small_march_distance = 0.5;
    float large_march_distance = 1.0;

    inline for (int l = 0; l < MAX_LIGHTS; l++) {
        float3 light_dir;
        float3 light_colour;
        if (!calculate_light(lights_data.lights[l], pos, light_dir, light_colour)) { continue; }
        if (length(light_dir) == 0.0) { continue; }
        if (length(light_colour) == 0.0) { continue; }

        // Compute approximate optical depth toward the light
        float ldensity = 0.0;
        float lt = 0.0;
        float max_length = length(lights_data.lights[l].position.xyz - pos);
        float3 lpos = pos - light_dir * lt;
        while (lt < max_length && lt < 20.0) {
            float density = shape_function(lpos) ? 0.01 : 0.0;

            // sample density at lpos (constant here)
            ldensity += density * small_march_distance;

            lt += small_march_distance;
            lpos = pos - light_dir * lt;
        }

        float lightTrans = exp(-ldensity);
        float3 lum = light_colour * cloud_albedo * (lightTrans);

        // Accumulate in-scattered light (additive) weighted by transmittance and step
        col += lum;
    }

    float alpha = 1.0 - exp(-tdensity);
    out_image.Store(dtid.xyz, float4(col.rgb, 0.0));
    return;
}
