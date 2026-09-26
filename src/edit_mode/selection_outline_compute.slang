#include "gfx/common.slang"

[[vk::binding(0, 0)]]
[[vk::image_format("r32ui")]]
RWTexture2D<uint> out_image;

[[vk::binding(1, 0)]]
Texture2D<uint> in_image;

struct PushConstants {
    uint selected_id;
    uint outline_px_width;
};

[[vk::push_constant]]
ConstantBuffer<PushConstants> push_constant;

// FIX: there is a bug where selecting entity 0 will also outline the border.
// Out-of-bounds loads return 0, not UINT32_MAX (the sentinel). Not a major issue.

groupshared uint gs_tile[10][10];

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 dtid: SV_DispatchThreadID, uint3 gtid: SV_GroupThreadID, uint3 gid: SV_GroupID)
{
    // Load a 10x10 halo tile (8x8 output + 1px border) into groupshared memory.
    // 100 texels across 64 threads: each thread loads 1, first 36 threads load 1 more.
    uint2 group_base = gid.xy * 8;
    uint flat_t = gtid.y * 8 + gtid.x;

    uint2 gs0 = uint2(flat_t % 10, flat_t / 10);
    gs_tile[gs0.y][gs0.x] = in_image.Load(int3(int2(group_base) - 1 + int2(gs0), 0));

    if (flat_t < 36) {
        uint flat_t2 = flat_t + 64;
        uint2 gs1 = uint2(flat_t2 % 10, flat_t2 / 10);
        gs_tile[gs1.y][gs1.x] = in_image.Load(int3(int2(group_base) - 1 + int2(gs1), 0));
    }
    GroupMemoryBarrierWithGroupSync();

    uint2 imageDim;
    out_image.GetDimensions(imageDim.x, imageDim.y);
    if (dtid.x >= imageDim.x || dtid.y >= imageDim.y) {
        return;
    }

    uint2 local = gtid.xy + 1;
    bool any_match = false;
    bool all_match = true;
    inline for (int i = -1; i <= 1; i++) {
        inline for (int j = -1; j <= 1; j++) {
            uint id = gs_tile[local.y + j][local.x + i];
            any_match = any_match || (id == push_constant.selected_id);
            all_match = all_match && (id == push_constant.selected_id);
        }
    }
    out_image.Store(dtid.xy, (any_match && !all_match) ? 1u : 0u);
}
