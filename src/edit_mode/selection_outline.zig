const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gfx = eng.gfx;
const StandardRenderer = @import("../render.zig");
const FileWatcher = eng.assets.FileWatcher;

const ComputeShaderPath = "../../src/edit_mode/selection_outline_compute.slang";
const RenderShaderPath = "../../src/edit_mode/selection_outline_render.slang";

const ComputePushConstant = extern struct {
    selected_id: u32,
    outline_px_width: u32,
};

const RenderPushConstant = extern struct {
    foo: f32 = 0.0,
};

compute_image: gfx.Image.Ref,
compute_view: gfx.ImageView.Ref,

sample_image: gfx.Image.Ref,
sample_view: gfx.ImageView.Ref,

selection_image: gfx.Image.Ref, // not owned by this class
selection_view: gfx.ImageView.Ref,

compute_shader_file_watcher: FileWatcher,
render_shader_file_watcher: FileWatcher,

compute_descriptor_layout: gfx.DescriptorLayout.Ref,
compute_descriptor_pool: gfx.DescriptorPool.Ref,
compute_descriptor_set: gfx.DescriptorSet.Ref,
compute_pipeline: gfx.ComputePipeline.Ref,

render_descriptor_layout: gfx.DescriptorLayout.Ref,
render_descriptor_pool: gfx.DescriptorPool.Ref,
render_descriptor_set: gfx.DescriptorSet.Ref,
render_render_pass: gfx.RenderPass.Ref,
render_framebuffer: gfx.FrameBuffer.Ref,
render_pipeline: gfx.GraphicsPipeline.Ref,

pub fn deinit(self: *Self) void {
    self.compute_view.deinit();
    self.compute_image.deinit();

    self.sample_view.deinit();
    self.sample_image.deinit();

    self.selection_view.deinit();

    self.compute_shader_file_watcher.deinit();
    self.render_shader_file_watcher.deinit();

    self.compute_pipeline.deinit();
    self.compute_descriptor_set.deinit();
    self.compute_descriptor_pool.deinit();
    self.compute_descriptor_layout.deinit();

    self.render_pipeline.deinit();
    self.render_framebuffer.deinit();
    self.render_render_pass.deinit();
    self.render_descriptor_set.deinit();
    self.render_descriptor_pool.deinit();
    self.render_descriptor_layout.deinit();
}

pub fn init(alloc: std.mem.Allocator, selection_image: gfx.Image.Ref) !Self {
    const selection_view = try gfx.ImageView.init(.{ .image = selection_image, .view_type = .ImageView2D, });
    errdefer selection_view.deinit();

    // compute image
    const compute_image = try gfx.Image.init(.{
        .match_swapchain_extent = true,
        .format = .R32_Uint,
        .usage_flags = .{ .StorageResource = true, .ShaderResource = true, },
        .access_flags = .{ .GpuWrite = true, },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer compute_image.deinit();

    const compute_image_view = try gfx.ImageView.init(.{ .image = compute_image, .view_type = .ImageView2D });
    errdefer compute_image_view.deinit();

    // sample image
    const sample_image = try gfx.Image.init(.{
        .match_swapchain_extent = true,
        .format = .R32_Uint,
        .usage_flags = .{ .TransferDst = true, .ShaderResource = true, },
        .access_flags = .{ .GpuWrite = true, },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer sample_image.deinit();

    const sample_image_view = try gfx.ImageView.init(.{ .image = sample_image, .view_type = .ImageView2D });
    errdefer sample_image_view.deinit();

    // compute descriptors
    const compute_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 0,
                .binding_type = .StorageImage,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 1,
                .binding_type = .ImageView,
            },
        },
    });
    errdefer compute_descriptor_layout.deinit();

    const compute_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = compute_descriptor_layout },
        .max_sets = 1,
    });
    errdefer compute_descriptor_pool.deinit();

    const compute_descriptor_set = try (try compute_descriptor_pool.get()).allocate_set(.{ .layout = compute_descriptor_layout });
    errdefer compute_descriptor_set.deinit();

    try (try compute_descriptor_set.get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .StorageImage = compute_image_view }, },
            .{ .binding = 1, .data = .{ .ImageView = sample_image_view }, },
        },
    });

    // render descriptors
    const render_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 0,
                .binding_type = .ImageView,
            },
        },
    });
    errdefer render_descriptor_layout.deinit();

    const render_descriptor_pool = try gfx.DescriptorPool.init(.{
        .max_sets = 1,
        .strategy = .{ .Layout = render_descriptor_layout, },
    });
    errdefer render_descriptor_pool.deinit();

    const render_descriptor_set = try (try render_descriptor_pool.get()).allocate_set(.{ .layout = render_descriptor_layout });
    errdefer render_descriptor_set.deinit();

    try (try render_descriptor_set.get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = compute_image_view }, },
        },
    });

    // render render pass
    const attachments = &[_]gfx.AttachmentInfo {
        gfx.AttachmentInfo {
            .name = "colour",
            .format = gfx.GfxState.ldr_format,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .Simple,
        },
    };

    const render_pass = try gfx.RenderPass.init(.{
        .attachments = attachments,
        .subpasses = &.{
            gfx.SubpassInfo {
                .attachments = &.{ "colour" },
            },
        },
        .dependencies = &.{
            gfx.SubpassDependencyInfo {
                .src_subpass = null,
                .dst_subpass = 0,
                .src_access_mask = .{},
                .src_stage_mask = .{ .color_attachment_output = true, },
                .dst_access_mask = .{ .color_attachment_write = true, },
                .dst_stage_mask = .{ .color_attachment_output = true, },
            },
        },
    });
    errdefer render_pass.deinit();

    const framebuffer = try gfx.FrameBuffer.init(.{
        .render_pass = render_pass,
        .attachments = &.{
            .SwapchainLDR,
        },
    });
    errdefer framebuffer.deinit();

    // compute shader file watcher
    const compute_path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.ComputeShaderPath });
    defer compute_path.deinit();

    const compute_path_resolved = try compute_path.resolve_path(alloc);
    defer alloc.free(compute_path_resolved);

    var compute_shader_file_watcher = try FileWatcher.init(alloc, compute_path_resolved, 1000);
    errdefer compute_shader_file_watcher.deinit();

    // render shader file watcher
    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.RenderShaderPath });
    defer path.deinit();

    const path_resolved = try path.resolve_path(alloc);
    defer alloc.free(path_resolved);

    var render_shader_file_watcher = try FileWatcher.init(alloc, path_resolved, 1000);
    errdefer render_shader_file_watcher.deinit();

    var self = Self {
        .compute_image = compute_image,
        .compute_view = compute_image_view,

        .sample_image = sample_image,
        .sample_view = sample_image_view,

        .selection_image = selection_image,
        .selection_view = selection_view,
        
        .compute_descriptor_layout = compute_descriptor_layout,
        .compute_descriptor_pool = compute_descriptor_pool,
        .compute_descriptor_set = compute_descriptor_set,
        .compute_pipeline = undefined,

        .render_descriptor_layout = render_descriptor_layout,
        .render_descriptor_pool = render_descriptor_pool,
        .render_descriptor_set = render_descriptor_set,
        .render_render_pass = render_pass,
        .render_framebuffer = framebuffer,
        .render_pipeline = undefined,

        .compute_shader_file_watcher = compute_shader_file_watcher,
        .render_shader_file_watcher = render_shader_file_watcher,
    };

    self.compute_pipeline = try self.create_compute_pipeline();
    self.render_pipeline = try self.create_render_pipeline();

    return self;
}

fn create_compute_pipeline(self: *Self) !gfx.ComputePipeline.Ref {
    const alloc = eng.get().general_allocator;

    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.ComputeShaderPath });
    defer path.deinit();

    const path_resolved = try path.resolve_path(alloc);
    defer alloc.free(path_resolved);

    const shader_file = try std.fs.openFileAbsolute(path_resolved, .{ .mode = .read_only });
    defer shader_file.close();

    const shader_slang = try alloc.alloc(u8, try shader_file.getEndPos());
    defer alloc.free(shader_slang);

    _ = try shader_file.readAll(shader_slang);

    const density_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = shader_slang,
        .shader_entry_points = &.{
            "cs_main",
        },
        .preprocessor_macros = &.{
        },
    });
    defer alloc.free(density_spirv);

    const density_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = density_spirv,
    });
    defer density_shader_module.deinit();

    const density_pipeline = try gfx.ComputePipeline.init(.{
        .compute_shader = .{
            .module = &density_shader_module,
            .entry_point = "cs_main",
        },
        .descriptor_set_layouts = &.{
            self.compute_descriptor_layout,
        },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(ComputePushConstant),
            }
        }
    });
    errdefer density_pipeline.deinit();

    return density_pipeline;
}

fn create_render_pipeline(self: *Self) !gfx.GraphicsPipeline.Ref {
    const alloc = eng.get().general_allocator;

    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.RenderShaderPath });
    defer path.deinit();

    const path_resolved = try path.resolve_path(alloc);
    defer alloc.free(path_resolved);

    const shader_file = try std.fs.openFileAbsolute(path_resolved, .{ .mode = .read_only });
    defer shader_file.close();

    const shader_slang = try alloc.alloc(u8, try shader_file.getEndPos());
    defer alloc.free(shader_slang);

    _ = try shader_file.readAll(shader_slang);

    const shader_spirv = try eng.get().gfx.shader_manager.generate_spirv(alloc, .{
        .shader_data = shader_slang,
        .shader_entry_points = &.{
            "vs_main",
            "ps_main",
        },
        .preprocessor_macros = &.{
        }
    });
    defer alloc.free(shader_spirv);

    const shader_module = try gfx.ShaderModule.init(.{ .spirv_data = shader_spirv });
    defer shader_module.deinit();

    const vertex_input = try gfx.VertexInput.init(.{
        .bindings = &.{},
        .attributes = &.{},
    });
    defer vertex_input.deinit();

    const pipeline = try gfx.GraphicsPipeline.init(.{
        .render_pass = self.render_render_pass,
        .subpass_index = 0,
        .vertex_shader = .{
            .module = &shader_module,
            .entry_point = "vs_main",
        },
        .vertex_input = &vertex_input,
        .pixel_shader = .{
            .module = &shader_module,
            .entry_point = "ps_main",
        },
        .depth_test = null,
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Pixel = true, },
                .offset = 0,
                .size = @sizeOf(RenderPushConstant),
            },
        },
        .topology = .TriangleList,
        .rasterization_fill_mode = .Fill,
        .front_face = .Clockwise,
        .descriptor_set_layouts = &.{
            self.render_descriptor_layout,
        },
    });
    errdefer pipeline.deinit();

    return pipeline;
}

pub fn render(self: *Self, cmd: *gfx.CommandBuffer, selected_id: u32) !void {
    if (self.compute_shader_file_watcher.was_modified_since_last_check()) blk: {
        const new_pipeline = self.create_compute_pipeline() catch |err| {
            std.log.err("Unable to update selection outine compute shader: {}", .{err});
            break :blk;
        };
        self.compute_pipeline.deinit();
        self.compute_pipeline = new_pipeline;
        eng.get().gfx.flush();
    }
    if (self.render_shader_file_watcher.was_modified_since_last_check()) blk: {
        const new_pipeline = self.create_render_pipeline() catch |err| {
            std.log.err("Unable to update selection outline render shader: {}", .{err});
            break :blk;
        };
        self.render_pipeline.deinit();
        self.render_pipeline = new_pipeline;
        eng.get().gfx.flush();
    }

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .color_attachment_output = true, },
        .dst_stage = .{ .transfer = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.selection_image,
                .src_access_mask = .{ .color_attachment_write = true, },
                .dst_access_mask = .{ .transfer_read = true, },
                .old_layout = .ColorAttachmentOptimal,
                .new_layout = .TransferSrcOptimal,
            },
        }
    });
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .fragment_shader = true, },
        .dst_stage = .{ .transfer = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.sample_image,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .transfer_write = true, },
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .TransferDstOptimal,
            },
        }
    });

    cmd.cmd_copy_image_to_image(.{
        .src_image = self.selection_image,
        .dst_image = self.sample_image,
        .copy_regions = &.{
            gfx.CommandBuffer.ImageCopyRegionInfo {
                .src_subresource = .{ .aspect_mask = .{ .colour = true, } },
                .dst_subresource = .{ .aspect_mask = .{ .colour = true, } },
                .extent = .{ eng.get().gfx.swapchain_size()[0], eng.get().gfx.swapchain_size()[1], 1 },
            },
        }
    });

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .transfer = true, },
        .dst_stage = .{ .color_attachment_output = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.selection_image,
                .src_access_mask = .{ .transfer_read = true, },
                .dst_access_mask = .{ .color_attachment_write = true, },
                .old_layout = .TransferSrcOptimal,
                .new_layout = .ColorAttachmentOptimal,
            },
        }
    });
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .transfer = true, },
        .dst_stage = .{ .compute_shader = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.sample_image,
                .src_access_mask = .{ .transfer_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
                .old_layout = .TransferDstOptimal,
                .new_layout = .ShaderReadOnlyOptimal,
            },
        }
    });
    
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .fragment_shader = true, },
        .dst_stage = .{ .compute_shader = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.compute_image,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
            },
        }
    });

    const compute_push_constants = ComputePushConstant {
        .selected_id = selected_id,
        .outline_px_width = 2,
    };

    cmd.cmd_bind_compute_pipeline(self.compute_pipeline);
    cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.compute_descriptor_set } });
    cmd.cmd_push_constants(.{ .data = std.mem.asBytes(&compute_push_constants), .offset = 0, .shader_stages = .{ .Compute = true, } });
    cmd.cmd_dispatch(.{ .group_count_x = eng.get().gfx.swapchain_size()[0], .group_count_y = eng.get().gfx.swapchain_size()[1], .group_count_z = 1, });

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .fragment_shader = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.compute_image,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
            },
        }
    });

    {
        cmd.cmd_begin_render_pass(.{
            .render_pass = self.render_render_pass,
            .framebuffer = self.render_framebuffer,
            .render_area = .full_screen_pixels(),
        });
        defer cmd.cmd_end_render_pass();

        const render_push_constants = RenderPushConstant {};

        cmd.cmd_bind_graphics_pipeline(self.render_pipeline);
        cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.render_descriptor_set, } });
        cmd.cmd_push_constants(.{ .data = std.mem.asBytes(&render_push_constants), .offset = 0, .shader_stages = .{ .Pixel = true, } });
        cmd.cmd_draw(.{ .vertex_count = 6, });
    }
}
