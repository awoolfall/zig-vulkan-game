// Self-contained: no includes (compiled via @embedFile).
// Computes the multi-scattering LUT (32x32 Rgba16_Float).
// numthreads(1,1,64): 32x32 texels, 64 threads each trace a Fibonacci-sphere direction x 20 steps.
// Paper equations 5-10 from Hillaire 2020.

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

[[vk::binding(0, 0)]]
ConstantBuffer<AtmosphereParams> params : register(b0);

[[vk::binding(1, 0)]]
Texture2D<float4> transmittance_lut;

[[vk::binding(2, 0)]]
SamplerState lut_sampler;

[[vk::binding(3, 0)]]
RWTexture2D<float4> multi_scatter_lut : register(u0);

groupshared float3 gs_L2nd[64];
groupshared float3 gs_fms[64];

float density_rayleigh(float h_km, float scale_height_km) {
    return exp(-h_km / scale_height_km);
}
float density_mie(float h_km, float scale_height_km) {
    return exp(-h_km / scale_height_km);
}
float density_ozone(float h_km) {
    return max(0.0, 1.0 - abs(h_km - 25.0) / 15.0);
}

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

float2 ray_sphere_intersect(float3 origin, float3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0) return float2(-1.0, -1.0);
    float sq = sqrt(disc);
    return float2(-b - sq, -b + sq);
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
    float sin_horizon = params.planet_radius_km / r_km;
    float cos_horizon = -sqrt(max(0.0, 1.0 - sin_horizon * sin_horizon));
    if (mu_sun < cos_horizon) return float3(0.0, 0.0, 0.0);
    float2 uv = rmu_to_transmittance_uv(r_km, mu_sun, params.planet_radius_km, params.atmosphere_radius_km);
    return transmittance_lut.SampleLevel(lut_sampler, uv, 0.0).rgb;
}

float isotropic_phase() { return 1.0 / (4.0 * PI); }

// Fibonacci sphere: 64 uniformly distributed unit directions
float3 fibonacci_sphere_dir(int i, int n) {
    float golden = (sqrt(5.0) + 1.0) * 0.5;
    float theta  = acos(1.0 - 2.0 * (float(i) + 0.5) / float(n));
    float phi    = 2.0 * PI * float(i) / golden;
    return float3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));
}

[numthreads(1, 1, 64)]
[shader("compute")]
void cs_main(uint3 dtid : SV_DispatchThreadID, uint3 gid : SV_GroupID, uint local_idx : SV_GroupIndex) {
    uint2 texel = gid.xy;  // 32x32 texels

    // Decode LUT UV to (h_km, cos_sun_zenith)
    float2 uv = (float2(texel) + 0.5) / 32.0;
    float cos_sun_zenith = 2.0 * uv.x - 1.0;  // u = 0.5 + 0.5*cos_sun
    float h_km = uv.y * (params.atmosphere_radius_km - params.planet_radius_km);
    float r_km = params.planet_radius_km + h_km;

    float3 sun_dir = float3(sqrt(max(0.0, 1.0 - cos_sun_zenith * cos_sun_zenith)), cos_sun_zenith, 0.0);

    // Each thread traces one direction from the 64-point Fibonacci sphere
    float3 omega_i = fibonacci_sphere_dir(int(local_idx), 64);

    float3 origin = float3(0.0, r_km, 0.0);

    // Find ray extent (atmosphere top, or ground if hit)
    float2 atm_hit = ray_sphere_intersect(origin, omega_i, params.atmosphere_radius_km);
    float2 gnd_hit = ray_sphere_intersect(origin, omega_i, params.planet_radius_km);
    float t_max = atm_hit.y;
    if (gnd_hit.x > 0.0) t_max = min(t_max, gnd_hit.x);  // stop at ground

    const int NUM_STEPS = 20;
    float dt = (t_max > 0.0) ? t_max / float(NUM_STEPS) : 0.0;

    float3 L2nd_i = float3(0.0, 0.0, 0.0);
    float3 fms_i  = float3(0.0, 0.0, 0.0);
    float3 T_accum = float3(1.0, 1.0, 1.0);

    for (int s = 0; s < NUM_STEPS; s++) {
        float t = (float(s) + 0.5) * dt;
        float3 pos = origin + omega_i * t;
        float h_s  = max(0.0, length(pos) - params.planet_radius_km);

        float3 sigma_s = scattering_at_height(h_s);
        float3 sigma_e = extinction_at_height(h_s);

        float mu_sun = dot(normalize(pos), sun_dir);
        float3 T_to_sun = sample_transmittance_to_sun(length(pos), mu_sun);

        float phase = isotropic_phase();

        // eq. 5-6: L2nd contribution weighted by transmittance along ray
        L2nd_i += T_accum * sigma_s * T_to_sun * phase * dt;

        // eq. 7-8: f_ms (same but no sun transmittance term)
        fms_i  += T_accum * sigma_s * phase * dt;

        T_accum *= exp(-sigma_e * dt);
    }

    // Ground bounce (Lambertian, eq. 5): add reflected light if ray hits ground
    if (gnd_hit.x > 0.0 && gnd_hit.x < atm_hit.y) {
        float3 gnd_pos  = origin + omega_i * gnd_hit.x;
        float  mu_sun_g = dot(normalize(gnd_pos), sun_dir);
        float3 T_gnd    = sample_transmittance_to_sun(params.planet_radius_km, mu_sun_g);
        float3 albedo   = params.ground_albedo.xyz;
        L2nd_i += T_accum * albedo * T_gnd * max(0.0, mu_sun_g) * (1.0 / PI);
    }

    gs_L2nd[local_idx] = L2nd_i;
    gs_fms[local_idx]  = fms_i;

    GroupMemoryBarrierWithGroupSync();

    // Parallel reduction (thread 0 sums, binary tree)
    if (local_idx == 0) {
        float3 L2nd_total = float3(0.0, 0.0, 0.0);
        float3 fms_total  = float3(0.0, 0.0, 0.0);
        for (int k = 0; k < 64; k++) {
            L2nd_total += gs_L2nd[k];
            fms_total  += gs_fms[k];
        }
        // Normalise by number of directions (sphere integral approximation)
        L2nd_total /= 64.0;
        fms_total  /= 64.0;

        // eq. 9-10: Psi_ms = L2nd / (1 - f_ms)
        float3 F_ms = float3(1.0, 1.0, 1.0) / max(float3(1e-7, 1e-7, 1e-7), float3(1.0, 1.0, 1.0) - fms_total);
        multi_scatter_lut[texel] = float4(L2nd_total * F_ms, 1.0);
    }
}
