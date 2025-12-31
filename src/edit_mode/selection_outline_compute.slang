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

bool kernel_any(uint3 dtid) {
    inline for (int i = -1; i <= 1; i++) {
        inline for (int j = -1; j <= 1; j++) {
            uint id = in_image.Load(uint3(dtid.xy + uint2(i, j), 0));
            if (id == push_constant.selected_id) {
                return true;
            }
        }
    }
    return false;
}

bool kernel_all(uint3 dtid) {
    inline for (int i = -1; i <= 1; i++) {
        inline for (int j = -1; j <= 1; j++) {
            uint id = in_image.Load(uint3(dtid.xy + uint2(i, j), 0));
            if (id != push_constant.selected_id) {
                return false;
            }
        }
    }
    return true;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void cs_main(uint3 dtid: SV_DispatchThreadID)
{
    uint2 pixelCoord = dtid.xy;
    uint2 imageDim;
    out_image.GetDimensions(imageDim.x, imageDim.y);

    if (pixelCoord.x >= imageDim.x || pixelCoord.y >= imageDim.y) {
        return;
    }

    bool is_selected = kernel_any(dtid) && !kernel_all(dtid);
    out_image.Store(dtid.xy, is_selected ? 1 : 0);
}
