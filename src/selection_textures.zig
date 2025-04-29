const std = @import("std");
const engine = @import("engine");
const gfx = engine.gfx;
const zm = engine.zmath;

pub fn SelectionTextures(comptime UnderlyingType: type) type {
    return struct {
        const Self = @This();
        const TextureFormat = switch (UnderlyingType) {
            u32 => gfx.TextureFormat.R32_Uint,
            f32 => gfx.TextureFormat.R32_Float,
            [2]f32 => gfx.TextureFormat.Rg32_Float,
            [4]f32 => gfx.TextureFormat.Rgba32_Float,
            else => @compileError("unsupported selection texture type"),
        };

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
                    .format = Self.TextureFormat,
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
                    .format = Self.TextureFormat,
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

        pub fn clear(self: *Self, gf: *gfx.GfxState, value: UnderlyingType) void {
            const v = switch (UnderlyingType) {
                u32 => zm.f32x4s(@floatFromInt(value)),
                f32 => zm.f32x4s(value),
                [2]f32 => zm.f32x4(value[0], value[1], value[0], value[1]),
                [4]f32 => zm.f32x4(value[0], value[1], value[2], value[3]),
                else => @compileError("unsupported selection texture type"),
            };
            gf.cmd_clear_render_target(&self.rtv, v);
        }

        pub fn get_value_at_position(self: *const Self, x: usize, y: usize, gf: *gfx.GfxState) !UnderlyingType {
            if (x >= self.texture.desc.width or y >= self.texture.desc.height) {
                return error.OutOfBounds;
            }

            gf.flush();
            gf.cmd_copy_texture_to_texture(&self.staging_texture, &self.texture);

            const mapped_texture = self.staging_texture.map(UnderlyingType, gf) catch |err| {
                std.log.err("cannot map: {}", .{err});
                return error.CannotMapStagingTexture;
            };
            defer mapped_texture.unmap();

            const idx: usize = @intCast(y * self.texture.desc.width + x);
            return mapped_texture.data()[idx];
        }
    };
}
