// atmosphere_common.slang content is prepended by atmosphere.zig before compilation.
// Generates a sky-colour cube map from the pre-computed sky-view LUT.
// Dispatch: (face_size/8, face_size/8, 6) — one group per 8x8 tile per face.

struct CubemapPushConstant {
    float3 sun_direction;
    float  camera_altitude_km;
};

[[vk::push_constant]]
ConstantBuffer<CubemapPushConstant> push;

[[vk::binding(0, 0)]]
ConstantBuffer<AtmosphereParams> params : register(b0);

[[vk::binding(1, 0)]]
Texture2D<float4> transmittance_lut;

[[vk::binding(2, 0)]]
Texture2D<float4> sky_view_lut;

[[vk::binding(3, 0)]]
SamplerState lut_sampler;

[[vk::binding(4, 0)]]
RWTexture2DArray<float4> output_cube;

// Map a face index and normalised UV in [0,1]^2 to a world-space direction.
// Follows the Vulkan cube-map face convention (spec §16.5.3.1):
//   face 0 = +X, 1 = -X, 2 = +Y, 3 = -Y, 4 = +Z, 5 = -Z
float3 cube_face_direction(uint face, float2 uv) {
    float s = 2.0 * uv.x - 1.0;
    float t = 2.0 * uv.y - 1.0;
    switch (face) {
        case 0:  return normalize(float3( 1.0,  -t,  -s)); // +X
        case 1:  return normalize(float3(-1.0,  -t,   s)); // -X
        case 2:  return normalize(float3(   s, 1.0,   t)); // +Y
        case 3:  return normalize(float3(   s,-1.0,  -t)); // -Y
        case 4:  return normalize(float3(   s,  -t, 1.0)); // +Z
        default: return normalize(float3(  -s,  -t,-1.0)); // -Z
    }
}

[numthreads(8, 8, 1)]
[shader("compute")]
void cs_main(uint3 global_id : SV_DispatchThreadID, uint3 group_id : SV_GroupID) {
    uint face = group_id.z;

    uint face_w, face_h, layer_count;
    output_cube.GetDimensions(face_w, face_h, layer_count);

    if (global_id.x >= face_w || global_id.y >= face_h) return;

    // Centre of this texel in [0,1] UV space
    float2 uv = (float2(global_id.xy) + 0.5) / float2(face_w, face_h);

    float3 ray_dir = cube_face_direction(face, uv);

    // Sample sky-view LUT (direction -> luminance at current camera altitude)
    float2 sky_uv  = direction_to_skyview_uv(ray_dir);
    float3 sky_lum = sky_view_lut.SampleLevel(lut_sampler, sky_uv, 0.0).rgb;

    // Sun disk (angular radius ~0.268 deg, same threshold as atmosphere_render.slang)
    float3 sun_dir = normalize(push.sun_direction);
    if (dot(ray_dir, sun_dir) > cos(0.004675)) {
        float r_km   = params.planet_radius_km + max(0.0, push.camera_altitude_km);
        float mu_sun = dot(float3(0.0, 1.0, 0.0), sun_dir);
        float3 T_sun = sample_transmittance_lut(transmittance_lut, lut_sampler, r_km, mu_sun,
                                                params.planet_radius_km, params.atmosphere_radius_km);
        sky_lum += T_sun * params.sun_irradiance.xyz;
    }

    output_cube[uint3(global_id.xy, face)] = float4(sky_lum, 1.0);
}
