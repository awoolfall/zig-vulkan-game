
[[vk::binding(0, 0)]]
[[vk::image_format("rgba32f")]]
RWTexture3D<float4> out_image;

[[vk::binding(1, 0)]]
Texture3D<float3> in_features_large;

[[vk::binding(2, 0)]]
Texture3D<float3> in_features_small;

// struct PushConstants {
//     uint foo;
// };

// [[vk::push_constant]]
// ConstantBuffer<PushConstants> push_constant;

[shader("compute")]
[numthreads(8, 8, 8)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    uint3 out_dim;
    out_image.GetDimensions(out_dim.x, out_dim.y, out_dim.z);

    if (dtid.x >= out_dim.x || dtid.y >= out_dim.y || dtid.z >= out_dim.z) return;

    uint3 features_large_dim;
    in_features_large.GetDimensions(features_large_dim.x, features_large_dim.y, features_large_dim.z);

    uint3 features_small_dim;
    in_features_small.GetDimensions(features_small_dim.x, features_small_dim.y, features_small_dim.z);

    const float3 uv = float3(dtid) / float3(out_dim);

    const uint3 center_feature_cell_large = uint3(floor(uv * float3(features_large_dim)));
    const uint3 center_feature_cell_small = uint3(floor(uv * float3(features_small_dim)));

    float min_distance_large = 1000.0;
    float min_distance_small = 1000.0;
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            for (int z = -1; z <= 1; z++) {
                const int3 test_cell_large = (int3(center_feature_cell_large) + int3(x, y, z)) % features_large_dim;
                const float3 test_feature_large = in_features_large.Load(int4(test_cell_large, 0));
                min_distance_large = min(min_distance_large, distance(float3(dtid), test_feature_large));

                const int3 test_cell_small = (int3(center_feature_cell_small) + int3(x, y, z)) % features_small_dim;
                const float3 test_feature_small = in_features_small.Load(int4(test_cell_small, 0));
                min_distance_small = min(min_distance_small, distance(float3(dtid), test_feature_small));
            }
        }
    }

    const float cell_texel_dim_large = float(out_dim.x / features_large_dim.x);
    const float voronoi_result_large = min_distance_large / (2.0 * cell_texel_dim_large);

    const float cell_texel_dim_small = float(out_dim.x / features_small_dim.x);
    const float voronoi_result_small = min_distance_small / (2.0 * cell_texel_dim_small);

    out_image.Store(dtid, float4(1.0 - voronoi_result_large, 1.0 - voronoi_result_small, 0.0, 0.0));
    return;
}
