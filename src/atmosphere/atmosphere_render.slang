// atmosphere_common.slang content is prepended by atmosphere.zig before compilation.
// This shader only needs gfx/common.slang from the engine search path.
#include "gfx/common.slang"

// Full-screen sky pass. Discards pixels where depth > 0 (geometry, reversed-Z convention).
// Samples sky-view LUT; adds sun disk using transmittance LUT.

struct RenderPushConstant {
    float4x4 inv_view_projection;
    float3   sun_direction;
    float    _pad0;
    float3   camera_position_km;
    float    _pad1;
};

[[vk::push_constant]]
ConstantBuffer<RenderPushConstant> push;

[[vk::binding(0, 0)]]
ConstantBuffer<AtmosphereParams> params : register(b0);

[[vk::binding(1, 0)]]
Texture2D<float4> sky_view_lut;

[[vk::binding(2, 0)]]
Texture2D<float4> transmittance_lut;

[[vk::binding(3, 0)]]
Texture2D depth_image;

[[vk::binding(4, 0)]]
SamplerState lut_sampler;

struct vs_out {
    float4 position  : SV_POSITION;
    float2 tex_coord : TEXCOORD0;
};

[shader("vertex")]
vs_out vs_main(uint vertId : SV_VertexID) {
    vs_out o = (vs_out)0;
    o.position  = full_screen_quad_vert(vertId);
    o.tex_coord = (o.position.xy + 1.0) * 0.5;
    return o;
}

struct ps_out {
    float4 colour : SV_TARGET0;
};

[shader("pixel")]
ps_out ps_main(vs_out input) {
    ps_out output = (ps_out)0;

    // Reversed-Z: sky = 0.0, geometry > 0.0
    uint2 depth_dims;
    depth_image.GetDimensions(depth_dims.x, depth_dims.y);
    float depth = depth_image.Load(uint3(uint2(input.tex_coord * float2(depth_dims)), 0)).r;
    if (depth > 0.0) discard;

    // Reconstruct view ray (matches cloud_render.slang convention)
    float2 ndc    = input.tex_coord * 2.0 - 1.0;
    float4 near_h = mul(float4(ndc, 1.0, 1.0), push.inv_view_projection);
    float4 far_h  = mul(float4(ndc, 0.0, 1.0), push.inv_view_projection);
    float3 ray_dir = normalize(far_h.xyz / far_h.w - near_h.xyz / near_h.w);

    // Sample sky-view LUT using direction -> UV mapping
    float2 sky_uv  = direction_to_skyview_uv(ray_dir);
    float3 sky_lum = sky_view_lut.SampleLevel(lut_sampler, sky_uv, 0.0).rgb;

    // Sun disk (angular radius ~0.268 deg)
    float3 sun_dir  = normalize(push.sun_direction);
    float  cos_sun  = dot(ray_dir, sun_dir);
    if (cos_sun > cos(0.004675)) {
        float r_km   = params.planet_radius_km + max(0.0, push.camera_position_km.y);
        float mu_sun = dot(float3(0.0, 1.0, 0.0), sun_dir);
        float3 T_sun = sample_transmittance_lut(transmittance_lut, lut_sampler, r_km, mu_sun,
                                                 params.planet_radius_km, params.atmosphere_radius_km);
        sky_lum += T_sun * params.sun_irradiance.xyz;
    }

    output.colour = float4(sky_lum, 1.0);
    return output;
}
