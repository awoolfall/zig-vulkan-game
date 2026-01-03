#include "gfx/common.slang"

#ifndef MAX_LIGHTS
#define MAX_LIGHTS 4
#endif

struct PushConstants
{
    float4x4 inv_view_projection_matrix;
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
Texture3D camera_lighting_grid_image;

[[vk::binding(2, 0)]]
Texture2D depth_image;

[[vk::binding(3, 0)]]
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

bool shape_function(float3 pos) {
    return pos.y < -5.0 && pos.y > -15.0;
    //return all(abs(pos) < 2.0);
}

float4 read_camera_lighting_grid(float2 uv, float world_depth) {
    float3 cell = float3(uv, sqrt((128.0 * world_depth)/5.0) / 64.0);//(log(world_depth / 160.0) + 64.0) / 64.0);
    return camera_lighting_grid_image.SampleLevel(diffuse_sampler, cell, 0.0);
}

struct ps_out
{
    float4 colour : SV_TARGET0;
};

[shader("pixel")]
ps_out ps_main(vs_out input)
{
    ps_out output = (ps_out)0;

    #if 0
    float4 occ = cloud_sample_image.SampleLevel(diffuse_sampler, input.tex_coord, 0);

    float3 hdr = float3(occ.rg, 0.0);
    float depth_t = occ.b;
    float alpha = occ.a;

    uint2 depthDim;
    depth_image.GetDimensions(depthDim.x, depthDim.y);

    float d = depth_image.Load(uint3(uint2(input.tex_coord * float2(depthDim)), 0)).r;
    //if (d > depth_t) { output.colour = float4(d, depth_t, 0.0, 1.0); return output; }

    // Premultiply alpha
    float3 premul = hdr * alpha;

    float dd = depth_t - d;

    output.colour = float4(premul, alpha);
    #endif

    uint3 camera_lighting_grid_dim;
    camera_lighting_grid_image.GetDimensions(camera_lighting_grid_dim.x, camera_lighting_grid_dim.y, camera_lighting_grid_dim.z);

    // Calculate normalized device coordinates [-1, 1]
    float2 ndc = (input.tex_coord.xy * 2.0) - 1.0;

    // Reconstruct world space position at near and far plane
    float4 nearPoint = mul(float4(ndc, 1.0, 1.0), push_constant.inv_view_projection_matrix); // Near plane (depth = 0 in Vulkan)
    float4 farPoint = mul(float4(ndc, 0.0, 1.0), push_constant.inv_view_projection_matrix);  // Far plane (depth = 1 in Vulkan)

    // Perspective divide
    nearPoint.xyz /= nearPoint.w;
    farPoint.xyz /= farPoint.w;

    // Calculate ray direction and origin
    float3 rayDir = normalize(farPoint.xyz - nearPoint.xyz);
    float3 origin = nearPoint.xyz;

    // Sample depth
    uint2 depthDim;
    depth_image.GetDimensions(depthDim.x, depthDim.y);
    float opaque_depth = depth_image.Load(uint3(uint2(input.tex_coord.xy * float2(depthDim)), 0)).r;
    float3 depth_world_pos = calculate_depth_frag_in_world_pos(opaque_depth, ndc, push_constant.inv_view_projection_matrix);

    float max_march_distance = 160.0;
    const float small_march_distance = 0.1;
    const float large_march_distance = 1.0;

    float tmarch_distance = large_march_distance;

    // Project the reconstructed depth point onto the world-space ray to get
    // the distance along the ray where the opaque geometry lies.
    float opaque_t = length(depth_world_pos - origin);//, rayDir);
    if (opaque_t < 0.0) opaque_t = 0.0;
    //opaque_t = 1000.0;

    max_march_distance = min(max_march_distance, opaque_t);

    float tdensity = 0.0;
    float3 col = float3(0.0, 0.0, 0.0);

    float mt = large_march_distance;
    float tt = mt;
    while (tt < max_march_distance) {
        mt = large_march_distance;
        while (tt < max_march_distance) {
            float3 pos = origin + rayDir * tt;
            if (shape_function(pos)) break;
            tt += mt;
        }

        float rt = tt;
        tt -= mt;

        mt = small_march_distance;
        while (tt < max_march_distance) {
            float3 pos = origin + rayDir * tt;
            if (!shape_function(pos)) {
                if (tt <= rt) {
                    tt += mt;
                    continue;
                } else {
                    break;
                }
            }
            
            float density = 0.01;
            
            // Advance optical depth along the ray
            tdensity += density * mt;
            //col += float3(1.0, 1.0, 1.0) * density;
            //if (tt <= (Z_GRID_CELL_DISTANCE * camera_lighting_grid_dim.z)) {
            col += (1.0 - exp(-tdensity)) * read_camera_lighting_grid(input.tex_coord, tt).rgb * mt;
            //}
            tt += mt;
        }
    }

    //tt -= mt;
    //float final_step = max_march_distance - tt;
    //tdensity += 0.1 * final_step;
    //col += (1.0 - exp(-tdensity)) * read_camera_lighting_grid(input.tex_coord, max_march_distance).rgb * final_step;

    float alpha = 1.0 - exp(-tdensity);
    output.colour = float4(col, alpha);

    return output;
}
