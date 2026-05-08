// atmosphere_common.slang is prepended at compile time.
// Single fullscreen compute pass combining sky rendering and aerial perspective:
//   depth == 0 (sky): samples sky-view LUT and sun disk, writes to HDR.
//   depth > 0 (geometry): reads HDR scene colour, applies aerial perspective LUT, writes back.
// numthreads(8,8,1) -- dispatch ceil(W/8) x ceil(H/8) x 1.

struct SkyAerialPushConstant {
    float4x4 inv_view_projection;
    float3   sun_direction;
    float    _pad0;
    float3   camera_position_km;
    float    aerial_km_per_slice;
};

[[vk::binding(0, 0)]] RWTexture2D<float4>              hdr_image;
[[vk::binding(1, 0)]] Texture2D<float>                 depth_image;
[[vk::binding(2, 0)]] Texture3D<float4>                aerial_lut;
[[vk::binding(3, 0)]] Texture2D<float4>                sky_view_lut;
[[vk::binding(4, 0)]] Texture2D<float4>                transmittance_lut;
[[vk::binding(5, 0)]] ConstantBuffer<AtmosphereParams>  params;
[[vk::binding(6, 0)]] SamplerState                     lut_sampler;

[[vk::push_constant]]
ConstantBuffer<SkyAerialPushConstant> push;

[numthreads(8, 8, 1)]
[shader("compute")]
void cs_main(uint3 dtid : SV_DispatchThreadID) {
    uint2 dims;
    hdr_image.GetDimensions(dims.x, dims.y);
    if (dtid.x >= dims.x || dtid.y >= dims.y) return;

    float  depth     = depth_image.Load(uint3(dtid.xy, 0)).r;
    float2 screen_uv = (float2(dtid.xy) + 0.5) / float2(dims);
    float2 ndc       = screen_uv * 2.0 - 1.0;

    if (depth <= 0.0) {
        // Sky pixel: reconstruct view ray, sample sky-view LUT and add sun disk.
        float4 near_h  = mul(float4(ndc, 1.0, 1.0), push.inv_view_projection);
        float4 far_h   = mul(float4(ndc, 0.0, 1.0), push.inv_view_projection);
        float3 ray_dir = normalize(far_h.xyz / far_h.w - near_h.xyz / near_h.w);

        float2 sky_uv  = direction_to_skyview_uv(ray_dir);
        float3 sky_lum = sky_view_lut.SampleLevel(lut_sampler, sky_uv, 0.0).rgb;

        float3 sun_dir = normalize(push.sun_direction);
        if (dot(ray_dir, sun_dir) > cos(0.004675)) {
            float  r_km   = params.planet_radius_km + max(0.0, push.camera_position_km.y);
            float  mu_sun = dot(float3(0.0, 1.0, 0.0), sun_dir);
            float3 T_sun  = sample_transmittance_lut(transmittance_lut, lut_sampler, r_km, mu_sun,
                                                      params.planet_radius_km, params.atmosphere_radius_km);
            sky_lum += T_sun * params.sun_irradiance.xyz;
        }

        hdr_image[dtid.xy] = float4(sky_lum, 1.0);
    } else {
        // Geometry pixel: reconstruct world position and apply aerial perspective.
        float4 world_h      = mul(float4(ndc, depth, 1.0), push.inv_view_projection);
        float3 world_pos_km = world_h.xyz / (world_h.w * 1000.0);
        float  dist_km      = length(world_pos_km - push.camera_position_km);
        float  w            = dist_km / (push.aerial_km_per_slice * 32.0);

        float4 aerial     = aerial_lut.SampleLevel(lut_sampler, float3(screen_uv, w), 0.0);
        float  fog_amount = saturate(aerial.a);

        float3 scene_color = hdr_image[dtid.xy].rgb;
        hdr_image[dtid.xy] = float4(scene_color * (1.0 - fog_amount) + aerial.rgb, 1.0);
    }
}
