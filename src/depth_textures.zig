const Self = @This();

const std = @import("std");
const engine = @import("engine");
const gfx = engine.gfx;

texture: gfx.Image.Ref,
dsv: gfx.ImageView.Ref,
dsv_read_only: gfx.ImageView.Ref,

pub fn deinit(self: *Self) void {
    self.texture.deinit();
    self.dsv.deinit();
    self.dsv_read_only.deinit();
}

pub fn init() !Self {
    var self = Self {
        .texture = undefined,
        .dsv = undefined,
        .dsv_read_only = undefined,
    };
    try self.recreate(true);
    return self;
}

fn recreate(self: *Self, first_time: bool) !void {
    const texture = try gfx.Image.init(
        .{
            .match_swapchain_extent = true,
            .format = .D24S8_Unorm_Uint,

            .usage_flags = .{ .DepthStencil = true, },
            .access_flags = .{ .GpuWrite = true, },
            .dst_layout = .DepthStencilAttachmentOptimal,
        },
        null,
    );
    errdefer texture.deinit();

    const dsv = try gfx.ImageView.init(.{ .image = texture, });
    errdefer dsv.deinit();

    const view_read_only = try gfx.ImageView.init(.{ .image = texture, });
    errdefer view_read_only.deinit();

    if (!first_time) {
        self.deinit();
    }
    self.* = Self {
        .texture = texture,
        .dsv = dsv,
        .dsv_read_only = view_read_only,
    };
}

pub fn on_resize(self: *Self, gf: *gfx.GfxState) void {
    const image = self.texture.get() catch unreachable;
    if (image.info.width != gf.swapchain_size()[0] or image.info.height != gf.swapchain_size()[1]) {
        self.recreate(false) catch |err| {
            std.log.err("unable to recreate depth texture: {}", .{err});
        };
    }
}
