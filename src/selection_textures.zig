const std = @import("std");
const engine = @import("engine");
const gfx = engine.gfx;
const zm = engine.zmath;

pub fn SelectionTextures(comptime UnderlyingType: type) type {
    return struct {
        const Self = @This();
        const TextureFormat = switch (UnderlyingType) {
            u32 => gfx.ImageFormat.R32_Uint,
            f32 => gfx.ImageFormat.R32_Float,
            [2]f32 => gfx.ImageFormat.Rg32_Float,
            [4]f32 => gfx.ImageFormat.Rgba32_Float,
            else => @compileError("unsupported selection texture type"),
        };

        texture: gfx.Image.Ref,
        rtv: gfx.ImageView.Ref,
        staging_texture: gfx.Image.Ref,

        pub fn deinit(self: *Self) void {
            self.texture.deinit();
            self.rtv.deinit();
            self.staging_texture.deinit();
        }

        pub fn init() !Self {
            var self = Self {
                .texture = undefined,
                .rtv = undefined,
                .staging_texture = undefined,
            };
            try self.recreate(true);
            return self;
        }

        fn recreate(self: *Self, first_time: bool) !void {
            const texture = try gfx.Image.init(
                .{
                    .match_swapchain_extent = true,
                    .format = Self.TextureFormat,

                    .usage_flags = .{ .RenderTarget = true, .TransferSrc = true, },
                    .access_flags = .{ .GpuWrite = true, }
                },
                null,
            );
            errdefer texture.deinit();

            const rtv = try gfx.ImageView.init(.{ .image = texture, });
            errdefer rtv.deinit();

            const staging_texture = try gfx.Image.init(
                .{
                    .match_swapchain_extent = true,
                    .format = Self.TextureFormat,

                    .usage_flags = .{ .TransferDst = true, },
                    .access_flags = .{ .CpuRead = true, .GpuWrite = true, },
                },
                null,
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
            const image = self.texture.get() catch unreachable;
            if (image.info.width != gf.swapchain_size()[0] or image.info.height != gf.swapchain_size()[1]) {
                self.recreate(false) catch |err| {
                    std.log.err("unable to recreate depth texture: {}", .{err});
                };
            }
        }

        pub fn clear(self: *Self, value: UnderlyingType) void {
            const v = switch (UnderlyingType) {
                u32 => zm.f32x4s(@floatFromInt(value)),
                f32 => zm.f32x4s(value),
                [2]f32 => zm.f32x4(value[0], value[1], value[0], value[1]),
                [4]f32 => zm.f32x4(value[0], value[1], value[2], value[3]),
                else => @compileError("unsupported selection texture type"),
            };
            gfx.GfxState.get().cmd_clear_render_target(self.rtv, v);
        }

        pub fn get_value_at_position(self: *const Self, x: usize, y: usize, gf: *gfx.GfxState) !UnderlyingType {
            _ = self;
            _ = x;
            _ = y;
            _ = gf;
            return error.ThisNeedsFixing;
            // const image = try self.texture.get();
            // if (x >= image.info.width or y >= image.info.height) {
            //     return error.OutOfBounds;
            // }
            //
            // gf.flush();
            // gf.cmd_copy_texture_to_texture(self.staging_texture, self.texture);
            //
            // const staging_image = try self.staging_texture.get();
            // const mapped_texture = staging_image.map(.{ .read = true, }) catch |err| {
            //     std.log.err("cannot map: {}", .{err});
            //     return error.CannotMapStagingTexture;
            // };
            // defer mapped_texture.unmap();
            //
            // const idx: usize = @intCast(y * image.info.width + x);
            // return mapped_texture.data(UnderlyingType)[idx];
        }
    };
}
