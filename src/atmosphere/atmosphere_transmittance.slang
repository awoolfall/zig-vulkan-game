// Self-contained: no includes (compiled via @embedFile).
// Computes the transmittance LUT (256x64 Rgba16_Float) using Bruneton-Neyret parameterization.
// numthreads(8,8,1), dispatch (32,8,1) -> 256x64 exact.

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
RWTexture2D<float4> transmittance_lut : register(u0);

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
    float3 ext_R = params.rayleigh_scattering.xyz * d_R;
    float3 ext_M = (params.mie_params.x + params.mie_params.y) * d_M;
    float3 ext_O = params.ozone_absorption.xyz * d_O;
    return ext_R + ext_M + ext_O;
}

// Bruneton-Neyret parameterization: UV -> (r_km, mu)
void transmittance_uv_to_rmu(float2 uv, float r_bot, float r_top, out float r_km, out float mu) {
    float H   = sqrt(max(0.0, r_top * r_top - r_bot * r_bot));
    float rho = H * uv.y;
    r_km      = sqrt(rho * rho + r_bot * r_bot);
    float d_min = r_top - r_km;
    float d_max = rho + H;
    float d   = d_min + uv.x * (d_max - d_min);
    mu = (d == 0.0) ? 1.0 : clamp((H * H - rho * rho - d * d) / (2.0 * r_km * d), -1.0, 1.0);
}

// Ray-sphere intersection (returns far-t for atmosphere top; -1 if no hit)
float ray_sphere_far(float3 origin, float3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0) return -1.0;
    return -b + sqrt(disc);
}

[numthreads(8, 8, 1)]
[shader("compute")]
void cs_main(uint3 dtid : SV_DispatchThreadID) {
    uint2 dims;
    transmittance_lut.GetDimensions(dims.x, dims.y);
    if (dtid.x >= dims.x || dtid.y >= dims.y) return;

    float2 uv = (float2(dtid.xy) + 0.5) / float2(dims);

    float r_km, mu;
    transmittance_uv_to_rmu(uv, params.planet_radius_km, params.atmosphere_radius_km, r_km, mu);

    float3 origin = float3(0.0, r_km, 0.0);
    float3 dir    = float3(sqrt(max(0.0, 1.0 - mu * mu)), mu, 0.0);

    float t_max = ray_sphere_far(origin, dir, params.atmosphere_radius_km);
    if (t_max < 0.0) {
        transmittance_lut[dtid.xy] = float4(1.0, 1.0, 1.0, 1.0);
        return;
    }

    const int NUM_STEPS = 40;
    float dt = t_max / float(NUM_STEPS);
    float3 optical_depth = float3(0.0, 0.0, 0.0);

    for (int i = 0; i < NUM_STEPS; i++) {
        float t = (float(i) + 0.5) * dt;
        float3 pos = origin + dir * t;
        float h_km = max(0.0, length(pos) - params.planet_radius_km);
        optical_depth += extinction_at_height(h_km) * dt;
    }

    transmittance_lut[dtid.xy] = float4(exp(-optical_depth), 1.0);
}
