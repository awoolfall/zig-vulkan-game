// atmosphere_common.slang content is prepended by atmosphere.zig before compilation.
// This shader only needs gfx/common.slang from the engine search path.
#include "gfx/common.slang"

// Per-frame sky-view LUT (200x100). Stores single+multi scatter luminance for each
// view direction at the camera altitude. numthreads(8,8,1), dispatch (25,13,1).

[[vk::binding(0, 0)]]
ConstantBuffer<AtmosphereParams> params : register(b0);

[[vk::binding(1, 0)]]
Texture2D<float4> transmittance_lut;

[[vk::binding(2, 0)]]
Texture2D<float4> multi_scatter_lut;

[[vk::binding(3, 0)]]
SamplerState lut_sampler;

[[vk::binding(4, 0)]]
RWTexture2D<float4> sky_view_lut : register(u0);

struct SkyViewPushConstant {
    float3 sun_direction;
    float  camera_altitude_km;
};

[[vk::push_constant]]
ConstantBuffer<SkyViewPushConstant> push;

float2 ray_sphere_isect(float3 o, float3 d, float r) {
    float b = dot(o, d);
    float c = dot(o, o) - r * r;
    float disc = b * b - c;
    if (disc < 0.0) return float2(-1.0, -1.0);
    float sq = sqrt(disc);
    return float2(-b - sq, -b + sq);
}

[numthreads(8, 8, 1)]
[shader("compute")]
void cs_main(uint3 dtid : SV_DispatchThreadID) {
    if (dtid.x >= 200 || dtid.y >= 100) return;

    float2 uv = (float2(dtid.xy) + 0.5) / float2(200.0, 100.0);

    // Decode UV -> world-space view direction (Y-up), non-linear latitude (paper §5.3)
    float3 view_dir = skyview_uv_to_direction(uv);

    float r_km     = params.planet_radius_km + max(0.0, push.camera_altitude_km);
    float3 origin  = float3(0.0, r_km, 0.0);
    float3 sun_dir = normalize(push.sun_direction);
    float cos_theta = dot(view_dir, sun_dir);

    float2 atm_hit = ray_sphere_isect(origin, view_dir, params.atmosphere_radius_km);
    float2 gnd_hit = ray_sphere_isect(origin, view_dir, params.planet_radius_km);

    float t_max = atm_hit.y;
    if (t_max <= 0.0) {
        sky_view_lut[dtid.xy] = float4(0.0, 0.0, 0.0, 1.0);
        return;
    }
    if (gnd_hit.x > 0.0) t_max = min(t_max, gnd_hit.x);

    const int NUM_STEPS = 30;
    float dt = t_max / float(NUM_STEPS);

    float3 L       = float3(0.0, 0.0, 0.0);
    float3 T_total = float3(1.0, 1.0, 1.0);
    float3 L_sun   = params.sun_irradiance.xyz;

    for (int i = 0; i < NUM_STEPS; i++) {
        float  t   = (float(i) + 0.5) * dt;
        float3 pos = origin + view_dir * t;
        float  r_s = length(pos);
        float  h_s = max(0.0, r_s - params.planet_radius_km);

        MediumSample med = sample_medium(h_s, params);
        float3 sigma_e   = med.sigma_ext;

        float mu_sun    = dot(normalize(pos), sun_dir);
        float3 T_to_sun = sample_transmittance_to_sun(transmittance_lut, lut_sampler, r_s, mu_sun,
                                                       params.planet_radius_km, params.atmosphere_radius_km);
        float3 psi_ms   = sample_multiscatter_lut(multi_scatter_lut, lut_sampler, h_s, mu_sun,
                                                   params.planet_radius_km, params.atmosphere_radius_km);

        float phase_R = rayleigh_phase(cos_theta);
        float phase_M = mie_phase_cornette_shanks(params.mie_params.w, cos_theta);

        float3 single = T_total * (med.sigma_s_R * phase_R + med.sigma_s_M * phase_M) * T_to_sun * L_sun;
        float3 multi  = T_total * (med.sigma_s_R + med.sigma_s_M) * psi_ms;

        L       += (single + multi) * dt;
        T_total *= exp(-sigma_e * dt);
    }

    sky_view_lut[dtid.xy] = float4(L, 1.0);
}
