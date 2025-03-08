const Self = @This();

const std = @import("std");
const engine = @import("engine");
const gfx = engine.gfx;

texture: gfx.Texture2D,
dsv: gfx.DepthStencilView,
dsv_read_only: gfx.DepthStencilView,

pub fn deinit(self: *Self) void {
    self.texture.deinit();
    self.dsv.deinit();
    self.dsv_read_only.deinit();
}

pub fn init(gf: *gfx.GfxState) !Self {
    var self = Self {
        .texture = undefined,
        .dsv = undefined,
        .dsv_read_only = undefined,
    };
    try self.recreate(gf, true);
    return self;
}

fn recreate(self: *Self, gf: *gfx.GfxState, first_time: bool) !void {
    const texture = try gfx.Texture2D.init(
        .{
            .width = @intCast(gf.swapchain_size.width),
            .height = @intCast(gf.swapchain_size.height),
            .format = .D24S8_Unorm_Uint,
        },
        .{ .DepthStencil = true, },
        .{ .GpuWrite = true, },
        null,
        gf
    );
    errdefer texture.deinit();

    const dsv = try gfx.DepthStencilView.init_from_texture2d(&texture, .{}, gf);
    errdefer dsv.deinit();

    const view_read_only = try gfx.DepthStencilView.init_from_texture2d(&texture, .{ .read_only_depth = true, }, gf);
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
    if (self.texture.desc.width != gf.swapchain_size.width or self.texture.desc.height != gf.swapchain_size.height) {
        self.recreate(gf, false) catch |err| {
            std.log.err("unable to recreate depth texture: {}", .{err});
        };
    }
}
