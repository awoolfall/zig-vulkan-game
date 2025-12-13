#ifndef TEX_SIZE
#define TEX_SIZE 1
#endif

#define PI 3.141592653589

[[vk::binding(0, 0)]]
Texture2D<float2> gaussian_random : register(t0);

[[vk::binding(1, 0)]]
[[vk::image_format("rg32f")]]
WTexture2D<float2> out_h0_tilde;

struct PushConstants {
    float map_length_m;
    float amplitude;
    float2 wind;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

inline int alias(int x) {
    if (x >= (TEX_SIZE / 2)) {
        return x - TEX_SIZE;
    } else {
        return x;
    }
}

inline float2 calc_k(const float n, const float m, const float Lx, const float Lz) {
    const float kx = 2.0 * PI * n / Lx;
    const float kz = 2.0 * PI * m / Lz;
    return float2(kx, kz);
}

inline float2 compute_h0_tilde(float2 gaussian_random, float amplitude, float2 wind, float2 k) {
    const float phillips_k = phillips(amplitude, wind, k);
    const float scalar = sqrt(phillips_k * 0.5);
    return gaussian_random * float2(scalar, scalar);
}

inline float phillips(float amplitude, float2 wind, float2 k) {
    const float v = length(wind);
    const float eps = 1e-6;
    if (v < eps) { return 0.0; }
    const float L_ = (v * v) / 9.81;
    const float k_length = length(k);
    if (k_length < 0.0001) { return 0.0; }
    const float2 nk = normalize(k);
    const float2 nw = normalize(wind);
    const float cosine_factor = pow(dot(nk, nw), 2.0);
    const float l = push_constant.map_length_m / (TEX_SIZE * 2.0); // suppress waves below half the smallest facet size
    const float k2 = k_length * k_length;
    const float suppress_small_waves = exp(-1.0 * (k2) * (l * l));
    const float denom = k2 * k2; // k^4
    return (amplitude / denom) * exp(-1.0 / (k2 * L_ * L_)) * cosine_factor * suppress_small_waves;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    int2 uuv = dtid.xy;

    const int n = alias(int(uuv.x));
    const int m = alias(int(uuv.y));

    const float2 k = calc_k(n, m, push_constant.map_length_m, push_constant.map_length_m);

    const float2 g = gaussian_random.Load(int3(uuv, 0));
    const float2 h0_val = compute_h0_tilde(g, push_constant.amplitude, push_constant.wind, k);

    out_h0_tilde.Store(uuv, h0_val);
}
