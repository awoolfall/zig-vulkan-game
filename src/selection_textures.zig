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

        image: gfx.Image.Ref,
        view: gfx.ImageView.Ref,
        staging_buffer: gfx.Buffer.Ref,

        command_pool: gfx.CommandPool.Ref,
        command_buffer: gfx.CommandBuffer,

        pub fn deinit(self: *Self) void {
            self.view.deinit();
            self.image.deinit();
            self.staging_buffer.deinit();

            self.command_buffer.deinit();
            self.command_pool.deinit();
        }

        pub fn init() !Self {
            const staging_buffer = try gfx.Buffer.init(
                @sizeOf(u32) * 1,
                .{ .TransferDst = true, },
                .{ .CpuRead = true, .GpuWrite = true, }
            );
            errdefer staging_buffer.deinit();

            const command_pool = try gfx.CommandPool.init(.{
                .allow_reset_command_buffers = true,
                .queue_family = .Graphics,
            });
            errdefer command_pool.deinit();

            const cmd_buffer = try (command_pool.get() catch unreachable).allocate_command_buffer(.{});
            errdefer cmd_buffer.deinit();

            var self = Self {
                .image = undefined,
                .view = undefined,
                .staging_buffer = staging_buffer,
                .command_pool = command_pool,
                .command_buffer = cmd_buffer,
            };

            try self.recreate(true);

            return self;
        }

        fn recreate(self: *Self, first_time: bool) !void {
            const image = try gfx.Image.init(
                .{
                    .match_swapchain_extent = true,
                    .format = Self.TextureFormat,

                    .usage_flags = .{ .RenderTarget = true, .TransferSrc = true, },
                    .access_flags = .{ .GpuWrite = true, },
                    .dst_layout = .ColorAttachmentOptimal,
                },
                null,
            );
            errdefer image.deinit();

            const view = try gfx.ImageView.init(.{ .image = image, });
            errdefer view.deinit();

            if (!first_time) {
                self.deinit();
            }

            self.image = image;
            self.view = view;
        }

        pub fn on_resize(self: *Self, gf: *gfx.GfxState) void {
            const image = self.image.get() catch unreachable;
            if (image.info.width != gf.swapchain_size()[0] or image.info.height != gf.swapchain_size()[1]) {
                self.recreate(false) catch |err| {
                    std.log.err("unable to recreate selection texture: {}", .{err});
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

        pub fn get_value_at_position(self: *Self, x: usize, y: usize) !UnderlyingType {
            const cmd = &self.command_buffer;
            try cmd.reset();

            {
                try cmd.cmd_begin(.{ .one_time_submit = true, });

                cmd.cmd_pipeline_barrier(.{
                    .src_stage = .{ .color_attachment_output = true, },
                    .dst_stage = .{ .transfer = true, },
                    .image_barriers = &.{
                        gfx.CommandBuffer.ImageMemoryBarrierInfo {
                            .image = self.image,
                            .old_layout = .ColorAttachmentOptimal,
                            .new_layout = .TransferSrcOptimal,
                            .src_access_mask = .{ .color_attachment_write = true, },
                            .dst_access_mask = .{ .transfer_read = true, },
                        }
                    },
                    });

                cmd.cmd_copy_image_to_buffer(.{
                    .image = self.image,
                    .buffer = self.staging_buffer,
                    .image_offset = .{ @intCast(x), @intCast(y), 0 },
                    .image_extent = .{ 1, 1, 1 },
                });

                cmd.cmd_pipeline_barrier(.{
                    .src_stage = .{ .transfer = true, },
                    .dst_stage = .{ .color_attachment_output = true, },
                    .image_barriers = &.{
                        gfx.CommandBuffer.ImageMemoryBarrierInfo {
                            .image = self.image,
                            .old_layout = .TransferSrcOptimal,
                            .new_layout = .ColorAttachmentOptimal,
                            .src_access_mask = .{ .transfer_read = true, },
                            .dst_access_mask = .{ .color_attachment_write = true, },
                        }
                    },
                    });

                try cmd.cmd_end();
            }

            var fence = try gfx.Fence.init(.{});
            defer fence.deinit();

            try gfx.GfxState.get().submit_command_buffer(gfx.GfxState.SubmitInfo {
                .command_buffers = &.{ cmd },
                .fence = fence,
            });

            try fence.wait();
            
            const mapped_buffer = try (try self.staging_buffer.get()).map(.{ .read = true, });
            defer mapped_buffer.unmap();

            const value: UnderlyingType = mapped_buffer.data(UnderlyingType).*;
            std.log.info("selected value as {any}", .{value});
            return value;
        }
    };
}
