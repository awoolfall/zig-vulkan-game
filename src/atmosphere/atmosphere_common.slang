// Hillaire 2020 atmosphere math shared between sky_view and render shaders.
// Self-contained shaders (transmittance, multi_scattering, aerial_perspective) duplicate
// this math inline because @embedFile compilation has no file-path context for includes.

#ifndef PI
#define PI 3.14159265358979
#endif

// GPU layout: float4 for all 3-component vectors to avoid std140 alignment surprises.
struct AtmosphereParams {
    float4 rayleigh_scattering;    // xyz = sigma_s_R (km^-1), w = rayleigh_scale_height_km
    float4 mie_params;             // x = sigma_s_M, y = sigma_a_M, z = mie_scale_height_km, w = phase_g (km^-1)
    float4 ozone_absorption;       // xyz = sigma_a_O (km^-1), w = unused
    float4 ground_albedo;          // xyz = rho
    float4 sun_irradiance;         // xyz = E_sun (W/m^2 equiv)
    float planet_radius_km;
    float atmosphere_radius_km;
    float aerial_km_per_slice;
    float _pad;
};

// ---- Phase functions ----

float rayleigh_phase(float cos_theta) {
    return (3.0 / (16.0 * PI)) * (1.0 + cos_theta * cos_theta);
}

float mie_phase_cornette_shanks(float g, float cos_theta) {
    float g2 = g * g;
    float denom = pow(max(0.0, 1.0 + g2 - 2.0 * g * cos_theta), 1.5);
    return (3.0 / (8.0 * PI)) * (1.0 - g2) * (1.0 + cos_theta * cos_theta)
           / ((2.0 + g2) * max(denom, 1e-7));
}

float isotropic_phase() {
    return 1.0 / (4.0 * PI);
}

// ---- Density profiles (paper §4) ----

float density_rayleigh(float h_km, float scale_height_km) {
    return exp(-h_km / scale_height_km);
}

float density_mie(float h_km, float scale_height_km) {
    return exp(-h_km / scale_height_km);
}

// Ozone: tent function max(0, 1 - |h-25| / 15)
float density_ozone(float h_km) {
    return max(0.0, 1.0 - abs(h_km - 25.0) / 15.0);
}

// ---- Medium sampling ----

struct MediumSample {
    float3 sigma_s_R;   // Rayleigh scattering
    float  sigma_s_M;   // Mie scattering
    float3 sigma_ext;   // total extinction per channel (R + M + O absorb)
};

MediumSample sample_medium(float h_km, AtmosphereParams params) {
    float d_R = density_rayleigh(h_km, params.rayleigh_scattering.w);
    float d_M = density_mie(h_km, params.mie_params.z);
    float d_O = density_ozone(h_km);

    MediumSample s;
    s.sigma_s_R  = params.rayleigh_scattering.xyz * d_R;
    s.sigma_s_M  = params.mie_params.x * d_M;
    float sigma_a_M = params.mie_params.y * d_M;
    float3 sigma_a_O = params.ozone_absorption.xyz * d_O;
    s.sigma_ext  = s.sigma_s_R + (s.sigma_s_M + sigma_a_M) + sigma_a_O;
    return s;
}

// ---- Ray-sphere intersection ----

// Returns (t_near, t_far). Negative t means behind ray origin.
float2 ray_sphere_intersect(float3 origin, float3 dir, float radius) {
    float a = dot(dir, dir);
    float b = 2.0 * dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float disc = b * b - 4.0 * a * c;
    if (disc < 0.0) return float2(-1.0, -1.0);
    float sq = sqrt(disc);
    return float2((-b - sq) / (2.0 * a), (-b + sq) / (2.0 * a));
}

// ---- Bruneton-Neyret transmittance LUT parameterization ([BN08] §4) ----

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

void transmittance_uv_to_rmu(float2 uv, float r_bot, float r_top, out float r_km, out float mu) {
    float H   = sqrt(max(0.0, r_top * r_top - r_bot * r_bot));
    float rho = H * uv.y;
    r_km      = sqrt(rho * rho + r_bot * r_bot);
    float d_min = r_top - r_km;
    float d_max = rho + H;
    float d   = d_min + uv.x * (d_max - d_min);
    mu = (d == 0.0) ? 1.0 : clamp((H * H - rho * rho - d * d) / (2.0 * r_km * d), -1.0, 1.0);
}

// ---- Transmittance LUT sampling ----

float3 sample_transmittance_lut(Texture2D lut, SamplerState samp, float r_km, float mu,
                                 float r_bot, float r_top) {
    float2 uv = rmu_to_transmittance_uv(r_km, mu, r_bot, r_top);
    return lut.SampleLevel(samp, uv, 0.0).rgb;
}

float3 sample_transmittance_to_sun(Texture2D lut, SamplerState samp, float r_km, float mu_sun,
                                    float r_bot, float r_top) {
    // Check if sun is below horizon: minimum mu for a ray to escape atmosphere
    float sin_horizon = r_bot / r_km;
    float cos_horizon = -sqrt(max(0.0, 1.0 - sin_horizon * sin_horizon));
    if (mu_sun < cos_horizon) return float3(0.0, 0.0, 0.0);
    return sample_transmittance_lut(lut, samp, r_km, mu_sun, r_bot, r_top);
}

// ---- Multi-scatter LUT sampling ----

float3 sample_multiscatter_lut(Texture2D lut, SamplerState samp, float h_km,
                                float cos_sun_zenith, float r_bot, float r_top) {
    float u = 0.5 + 0.5 * cos_sun_zenith;
    float v = clamp((h_km) / (r_top - r_bot), 0.0, 1.0);
    return lut.SampleLevel(samp, float2(u, v), 0.0).rgb;
}

// ---- Sky-view LUT UV mapping (paper §5.3) ----

// Direction (in world space, Y-up) → sky-view UV
float2 direction_to_skyview_uv(float3 dir) {
    float l = asin(clamp(dir.y, -1.0, 1.0));          // elevation [-PI/2, PI/2]
    float phi = atan2(dir.z, dir.x);                    // azimuth (-PI, PI]
    float u = (phi + PI) / (2.0 * PI);
    float v = 0.5 + 0.5 * sign(l) * sqrt(abs(l) / (PI * 0.5));
    return float2(u, v);
}

// Sky-view UV → direction
float3 skyview_uv_to_direction(float2 uv) {
    float phi = uv.x * 2.0 * PI - PI;
    float l_abs = (PI * 0.5) * (2.0 * uv.y - 1.0) * (2.0 * uv.y - 1.0);
    float l = (uv.y >= 0.5) ? l_abs : -l_abs;
    float cos_l = cos(l);
    return float3(cos_l * cos(phi), sin(l), cos_l * sin(phi));
}
