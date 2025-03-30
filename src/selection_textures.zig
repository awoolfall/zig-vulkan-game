const Self = @This();

const std = @import("std");
const engine = @import("engine");
const gfx = engine.gfx;

texture: gfx.Texture2D,
    rtv: gfx.RenderTargetView,
    staging_texture: gfx.Texture2D,

    pub fn deinit(self: *Self) void {
        self.texture.deinit();
        self.rtv.deinit();
        self.staging_texture.deinit();
    }

pub fn init(gf: *gfx.GfxState) !Self {
    var self = Self {
        .texture = undefined,
        .rtv = undefined,
        .staging_texture = undefined,
    };
    try self.recreate(gf, true);
    return self;
}

fn recreate(self: *Self, gf: *gfx.GfxState, first_time: bool) !void {
    const texture = try gfx.Texture2D.init(
        .{
            .width = @intCast(gf.swapchain_size.width),
            .height = @intCast(gf.swapchain_size.height),
            .format = .R32_Uint,
        },
        .{ .RenderTarget = true, },
        .{ .GpuWrite = true, },
        null,
        gf
    );
    errdefer texture.deinit();

    const rtv = try gfx.RenderTargetView.init_from_texture2d(&texture, gf);
    errdefer rtv.deinit();

    const staging_texture = try gfx.Texture2D.init(
        .{
            .width = @intCast(gf.swapchain_size.width),
            .height = @intCast(gf.swapchain_size.height),
            .format = .R32_Uint,
        },
        .{},
        .{ .CpuRead = true, .CpuWrite = true, .GpuWrite = true, },
        null,
        gf
    );
    errdefer texture.deinit();

    if (!first_time) {
        self.deinit();
    }
    self.* = Self {
        .texture = texture,
        .rtv = rtv,
        .staging_texture = staging_texture,
    };
}

pub fn on_resize(self: *Self, gf: *gfx.GfxState) void {
    if (self.texture.desc.width != gf.swapchain_size.width or self.texture.desc.height != gf.swapchain_size.height) {
        self.recreate(gf, false) catch |err| {
            std.log.err("unable to recreate depth texture: {}", .{err});
        };
    }
}

pub fn get_value_at_position(self: *const Self, x: usize, y: usize, gf: *gfx.GfxState) !u32 {
    if (x >= self.texture.desc.width or y >= self.texture.desc.height) {
        return error.OutOfBounds;
    }

    gf.flush();
    gf.cmd_copy_texture_to_texture(&self.staging_texture, &self.texture);

    const mapped_texture = self.staging_texture.map(u32, gf) catch |err| {
        std.log.err("cannot map: {}", .{err});
        return error.CannotMapStagingTexture;
    };
    defer mapped_texture.unmap();

    const idx: usize = @intCast(y * self.texture.desc.width + x);
    return mapped_texture.data()[idx];
}
