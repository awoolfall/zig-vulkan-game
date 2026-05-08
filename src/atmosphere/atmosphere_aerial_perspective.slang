// Self-contained: no includes (compiled via @embedFile).
// Computes the aerial perspective LUT (32x32x32 Rgba16_Float).
// Each voxel stores (in-scattered luminance rgb, 1-transmittance) from camera to that frustum point.
// numthreads(8,8,1), dispatch (4,4,32) -> 32x32x32 exact.

#define PI 3.14159265358979

struct AtmosphereParams {
    float4 rayleigh_scattering;  // xyz = sigma_s_R (km^-1), w = rayleigh_scale_height_km
    float4 mie_params;           // x = sigma_s_M, y = sigma_a_M, z = mie_scale_height_km, w = phase_g
    float4 ozone_absorption;     // xyz = sigma_a_O (km^-1)
    float4 ground_albedo;
    float4 sun_irradiance;
    float planet_radius_km;
    float atmosphere_radius_km;
    float aerial_km_per_slice;
    float _pad;
};

struct AerialPushConstant {
    float4x4 inv_view_projection;
    float3   sun_direction;
    float    _pad0;
    float3   camera_position_km;
    float    _pad1;
};

[[vk::binding(0, 0)]]
ConstantBuffer<AtmosphereParams> params : register(b0);

[[vk::binding(1, 0)]]
Texture2D<float4> transmittance_lut;

[[vk::binding(2, 0)]]
Texture2D<float4> multi_scatter_lut;

[[vk::binding(3, 0)]]
SamplerState lut_sampler;

[[vk::binding(4, 0)]]
RWTexture3D<float4> aerial_lut : register(u0);

[[vk::push_constant]]
ConstantBuffer<AerialPushConstant> push;

float density_rayleigh(float h_km, float scale) { return exp(-h_km / scale); }
float density_mie(float h_km, float scale)      { return exp(-h_km / scale); }
float density_ozone(float h_km)                 { return max(0.0, 1.0 - abs(h_km - 25.0) / 15.0); }

float3 extinction_at_height(float h_km) {
    float d_R = density_rayleigh(h_km, params.rayleigh_scattering.w);
    float d_M = density_mie(h_km, params.mie_params.z);
    float d_O = density_ozone(h_km);
    return params.rayleigh_scattering.xyz * d_R
         + (params.mie_params.x + params.mie_params.y) * d_M
         + params.ozone_absorption.xyz * d_O;
}

float3 scattering_at_height(float h_km) {
    float d_R = density_rayleigh(h_km, params.rayleigh_scattering.w);
    float d_M = density_mie(h_km, params.mie_params.z);
    return params.rayleigh_scattering.xyz * d_R + params.mie_params.x * d_M;
}

float2 rmu_to_transmittance_uv(float r_km, float mu, float r_bot, float r_top) {
    float H   = sqrt(max(0.0, r_top * r_top - r_bot * r_bot));
    float rho = sqrt(max(0.0, r_km * r_km - r_bot * r_bot));
    float disc = r_km * r_km * (mu * mu - 1.0) + r_top * r_top;
    float d    = max(0.0, -r_km * mu + sqrt(max(0.0, disc)));
    float d_min = r_top - r_km;
    float d_max = rho + H;
    float u = (d_max > d_min) ? (d - d_min) / (d_max - d_min) : 0.0;
    float v = (H > 0.0) ? rho / H : 0.0;
    return float2(u, v);
}

float3 sample_transmittance_to_sun(float r_km, float mu_sun) {
    float sin_h = params.planet_radius_km / r_km;
    float cos_h = -sqrt(max(0.0, 1.0 - sin_h * sin_h));
    if (mu_sun < cos_h) return float3(0.0, 0.0, 0.0);
    float2 uv = rmu_to_transmittance_uv(r_km, mu_sun, params.planet_radius_km, params.atmosphere_radius_km);
    return transmittance_lut.SampleLevel(lut_sampler, uv, 0.0).rgb;
}

float3 sample_multiscatter(float h_km, float cos_sun_zenith) {
    float u = 0.5 + 0.5 * cos_sun_zenith;
    float v = clamp(h_km / (params.atmosphere_radius_km - params.planet_radius_km), 0.0, 1.0);
    return multi_scatter_lut.SampleLevel(lut_sampler, float2(u, v), 0.0).rgb;
}

float mie_phase(float g, float cos_theta) {
    float g2 = g * g;
    float denom = pow(max(0.0, 1.0 + g2 - 2.0 * g * cos_theta), 1.5);
    return (3.0 / (8.0 * PI)) * (1.0 - g2) * (1.0 + cos_theta * cos_theta)
           / ((2.0 + g2) * max(denom, 1e-7));
}

float rayleigh_phase(float cos_theta) {
    return (3.0 / (16.0 * PI)) * (1.0 + cos_theta * cos_theta);
}

[numthreads(8, 8, 1)]
[shader("compute")]
void cs_main(uint3 dtid : SV_DispatchThreadID) {
    if (dtid.x >= 32 || dtid.y >= 32 || dtid.z >= 32) return;

    // Reconstruct world-space ray for this screen pixel
    float2 uv  = (float2(dtid.xy) + 0.5) / 32.0;
    float2 ndc = uv * 2.0 - 1.0;

    float4 near_h = mul(float4(ndc, 1.0, 1.0), push.inv_view_projection);
    float4 far_h  = mul(float4(ndc, 0.0, 1.0), push.inv_view_projection);
    float3 near_w = near_h.xyz / near_h.w;
    float3 far_w  = far_h.xyz  / far_h.w;
    float3 ray_dir = normalize(far_w - near_w);

    // Slice depth: camera to (slice + 0.5) * km_per_slice in km
    float slice_depth_km = (float(dtid.z) + 0.5) * params.aerial_km_per_slice;

    float3 cam_km = push.camera_position_km;
    float3 sun_dir = normalize(push.sun_direction);
    float cos_theta = dot(ray_dir, sun_dir);

    const int NUM_STEPS = 30;
    float dt = slice_depth_km / float(NUM_STEPS);

    float3 in_scatter = float3(0.0, 0.0, 0.0);
    float3 T_total    = float3(1.0, 1.0, 1.0);

    for (int i = 0; i < NUM_STEPS; i++) {
        float t = (float(i) + 0.5) * dt;
        float3 world_pos_km = cam_km + ray_dir * t;

        // Planet center at (0,0,0) in atmosphere coords; camera y maps to altitude
        float r_km  = params.planet_radius_km + max(0.0, world_pos_km.y);
        float h_km  = max(0.0, r_km - params.planet_radius_km);

        float3 sigma_s = scattering_at_height(h_km);
        float3 sigma_e = extinction_at_height(h_km);

        float3 up   = float3(0.0, 1.0, 0.0);
        float mu_sun = dot(up, sun_dir);

        float3 T_to_sun = sample_transmittance_to_sun(r_km, mu_sun);
        float3 psi_ms   = sample_multiscatter(h_km, mu_sun);

        float phase_R = rayleigh_phase(cos_theta);
        float phase_M = mie_phase(params.mie_params.w, cos_theta);

        float3 sigma_s_R = params.rayleigh_scattering.xyz * density_rayleigh(h_km, params.rayleigh_scattering.w);
        float  sigma_s_M = params.mie_params.x * density_mie(h_km, params.mie_params.z);

        float3 L_sun = params.sun_irradiance.xyz;
        float3 single_scatter = T_total * (sigma_s_R * phase_R + sigma_s_M * phase_M) * T_to_sun * L_sun;
        float3 multi_scatter  = T_total * sigma_s * psi_ms;

        in_scatter += (single_scatter + multi_scatter) * dt;
        T_total    *= exp(-sigma_e * dt);
    }

    float avg_transmittance = dot(T_total, float3(1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0));
    aerial_lut[dtid] = float4(in_scatter, 1.0 - avg_transmittance);
}
