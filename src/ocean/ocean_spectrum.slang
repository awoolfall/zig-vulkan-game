#ifndef TEX_SIZE
#define TEX_SIZE 1
#endif

#define PI 3.141592653589

[[vk::binding(0, 0)]]
Texture2D<float2> h0_tilde : register(t0);

[[vk::binding(1, 0)]]
[[vk::image_format("rgba32f")]]
WTexture2D<float4> out_ocean_displacement_r;

[[vk::binding(2, 0)]]
[[vk::image_format("rgba32f")]]
WTexture2D<float4> out_ocean_displacement_i;

[[vk::binding(3, 0)]]
[[vk::image_format("rgba32f")]]
WTexture2D<float4> out_ocean_slope_jacobian_r;

[[vk::binding(4, 0)]]
[[vk::image_format("rgba32f")]]
WTexture2D<float4> out_ocean_slope_jacobian_i;

struct PushConstants {
    float map_length_m;
    float time;
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

inline float2 complex_mul(const float2 a, const float2 b) {
    return float2(
        a.x * b.x - a.y * b.y, 
        a.x * b.y + a.y * b.x
    );
}

inline float2 h_tilde(const float t, const float2 k, const float2 h0_tilde_k, const float2 h0_tilde_nk) {
    const float g = 9.81;
    const float klen = length(k);
    const float eps = 1e-6;
    const float dispersion = sqrt(g * max(klen, eps));

    const float s = sin(dispersion * t);
    const float c = cos(dispersion * t);

    const float2 e = float2(c, s);
    const float2 ne = float2(c, -s);

    return complex_mul(h0_tilde_k, e) + complex_mul(h0_tilde_nk, ne);
}

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    int2 uuv = dtid.xy;

    const int n = alias(int(uuv.x));
    const int m = alias(int(uuv.y));

    const float2 h0_tilde_k = h0_tilde.Load(int3(uuv, 0));
    int nx = (TEX_SIZE - uuv.x) % TEX_SIZE;
    int ny = (TEX_SIZE - uuv.y) % TEX_SIZE;
    const float2 h0_tilde_nk = h0_tilde.Load(int3(int2(nx, ny), 0));

    const float2 k = calc_k(n, m, push_constant.map_length_m, push_constant.map_length_m);

    const float2 h_tilde_t = h_tilde(push_constant.time, k, h0_tilde_k, h0_tilde_nk);

    const float2 x = float2(n, m) * push_constant.map_length_m / TEX_SIZE;
    const float kdotx = dot(k, x);
    const float2 c = float2(cos(kdotx), sin(kdotx));
    const float2 h_tilde_c = complex_mul(h_tilde_t, c);

    const float2 slope_x = complex_mul(h_tilde_c, float2(0.0, k[0]));
    const float2 slope_z = complex_mul(h_tilde_c, float2(0.0, k[1]));

    float2 displacement_x = float2(0.0, 0.0);
    float2 displacement_z = float2(0.0, 0.0);
    const float klen = length(k);
    if (klen > 0.0001) {
        displacement_x = complex_mul(h_tilde_c, float2(0.0, -k[0] / klen));
        displacement_z = complex_mul(h_tilde_c, float2(0.0, -k[1] / klen));
    }

    // IFFT algorithm scales the output by 1/TEX_SIZE so that IFFT(FFT(x)) = x. However, we
    // dont want to do this for our spectrum. So we scale the IFFT input images by TEX_SIZE squared.

    const float tex_size2 = TEX_SIZE * TEX_SIZE;
    out_ocean_displacement_r.Store(uuv, float4(displacement_x.x, h_tilde_c.x, displacement_z.x, 0.0) * tex_size2 / push_constant.map_length_m);
    out_ocean_displacement_i.Store(uuv, float4(displacement_x.y, h_tilde_c.y, displacement_z.y, 0.0) * tex_size2 / push_constant.map_length_m);
    out_ocean_slope_jacobian_r.Store(uuv, float4(slope_x.x, 0.0, slope_z.x, 0.0) * tex_size2 / push_constant.map_length_m);
    out_ocean_slope_jacobian_i.Store(uuv, float4(slope_x.y, 0.0, slope_z.y, 0.0) * tex_size2 / push_constant.map_length_m);
}
