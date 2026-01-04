const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gfx = eng.gfx;
const StandardRenderer = @import("../render.zig");
const FileWatcher = eng.assets.FileWatcher;

const ComputeShaderPath = "../../src/clouds/cloud_compute.slang";
const RenderShaderPath = "../../src/clouds/cloud_render.slang";

const CAMERA_LIGHTING_GRID_IMAGE_SIZE: [3]u32 = .{ 160, 88, 64 };

const CloudDensityPushConstant = extern struct {
    inv_view_projection_matrix: zm.Mat,
};

const RenderPushConstant = extern struct {
    inv_view_projection_matrix: zm.Mat,
};

camera_lighting_grid_image: gfx.Image.Ref,
camera_lighting_grid_view: gfx.ImageView.Ref,

compute_shader_file_watcher: FileWatcher,
render_shader_file_watcher: FileWatcher,

lights_buffer: gfx.Buffer.Ref,
render_sampler: gfx.Sampler.Ref,

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
    self.camera_lighting_grid_image.deinit();
    self.camera_lighting_grid_view.deinit();

    self.lights_buffer.deinit();
    self.render_sampler.deinit();

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

pub fn init(alloc: std.mem.Allocator) !Self {
    // cloud density image
    const camera_lighting_grid_image = try gfx.Image.init(.{
        .match_swapchain_extent = false,
        .width = CAMERA_LIGHTING_GRID_IMAGE_SIZE[0],
        .height = CAMERA_LIGHTING_GRID_IMAGE_SIZE[1],
        .depth = CAMERA_LIGHTING_GRID_IMAGE_SIZE[2],
        .format = .Rgba32_Float,
        .usage_flags = .{ .StorageResource = true, .ShaderResource = true, },
        .access_flags = .{ .GpuWrite = true, },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer camera_lighting_grid_image.deinit();

    const camera_lighting_grid_view = try gfx.ImageView.init(.{ .image = camera_lighting_grid_image, .view_type = .ImageView3D });
    errdefer camera_lighting_grid_view.deinit();

    // compute resources
    const lights_buffer = try gfx.Buffer.init(
        @sizeOf(StandardRenderer.LightsStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer lights_buffer.deinit();
    
    const sampler = try gfx.Sampler.init(.{
        .filter_min_mag = .Linear,
        .filter_mip = .Linear,
        .border_mode = .Mirror,
    });
    errdefer sampler.deinit();

    // compute descriptors
    const density_descriptor_layout = try gfx.DescriptorLayout.init(.{
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
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 2,
                .binding_type = .UniformBuffer,
            }
        },
    });
    errdefer density_descriptor_layout.deinit();

    const density_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = density_descriptor_layout },
        .max_sets = 1,
    });
    errdefer density_descriptor_pool.deinit();

    const spectrum_descriptor_set = try (try density_descriptor_pool.get()).allocate_set(.{ .layout = density_descriptor_layout });
    errdefer spectrum_descriptor_set.deinit();

    try (try spectrum_descriptor_set.get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .StorageImage = camera_lighting_grid_view }, },
            .{ .binding = 1, .data = .{ .ImageView = eng.get().gfx.default.depth_view }, },
            .{ .binding = 2, .data = .{ .UniformBuffer = .{ .buffer = lights_buffer, } } },
        },
    });

    // render descriptors
    const render_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 0,
                .binding_type = .UniformBuffer,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 1,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 2,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 3,
                .binding_type = .Sampler,
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
            .{ .binding = 0, .data = .{ .UniformBuffer = .{ .buffer = lights_buffer, } } },
            .{ .binding = 1, .data = .{ .ImageView = camera_lighting_grid_view }, },
            .{ .binding = 2, .data = .{ .ImageView = eng.get().gfx.default.depth_view }, },
            .{ .binding = 3, .data = .{ .Sampler = sampler }, },
        },
    });

    // render render pass
    const attachments = &[_]gfx.AttachmentInfo {
        gfx.AttachmentInfo {
            .name = "colour",
            .format = gfx.GfxState.hdr_format,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .PremultipliedAlpha,
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
            .SwapchainHDR,
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
        .camera_lighting_grid_image = camera_lighting_grid_image,
        .camera_lighting_grid_view = camera_lighting_grid_view,

        .lights_buffer = lights_buffer,
        .render_sampler = sampler,
        
        .compute_descriptor_layout = density_descriptor_layout,
        .compute_descriptor_pool = density_descriptor_pool,
        .compute_descriptor_set = spectrum_descriptor_set,
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
                .size = @sizeOf(CloudDensityPushConstant),
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
            .{ "MAX_LIGHTS", std.fmt.comptimePrint("{}", .{ 4 }) },
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
        .depth_test = null,//.{ .write = false, },
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

pub fn render(self: *Self, cmd: *gfx.CommandBuffer, camera: *const eng.camera.Camera, standard_renderer: *StandardRenderer) !void {
    if (self.compute_shader_file_watcher.was_modified_since_last_check()) blk: {
        const new_pipeline = self.create_compute_pipeline() catch |err| {
            std.log.err("Unable to update cloud compute shader: {}", .{err});
            break :blk;
        };
        self.compute_pipeline.deinit();
        self.compute_pipeline = new_pipeline;
        eng.get().gfx.flush();
    }
    if (self.render_shader_file_watcher.was_modified_since_last_check()) blk: {
        const new_pipeline = self.create_render_pipeline() catch |err| {
            std.log.err("Unable to update cloud render shader: {}", .{err});
            break :blk;
        };
        self.render_pipeline.deinit();
        self.render_pipeline = new_pipeline;
        eng.get().gfx.flush();
    }

    (blk: {
        const lights_buffer = self.lights_buffer.get() catch break :blk error.UnableToGetBuffer;
        const mapped_buffer = lights_buffer.map(.{ .write = .EveryFrame, }) catch break :blk error.UnableToMapBuffer;
        defer mapped_buffer.unmap();

        const data = mapped_buffer.data_array(StandardRenderer.LightsStruct, 1);
        standard_renderer.sort_lights(
            camera.transform.position
        );
        const max_lights = @min(StandardRenderer.MAX_LIGHTS, standard_renderer.lights.items.len);
        @memcpy(data[0].lights[0..max_lights], standard_renderer.lights.items[0..max_lights]);
    }) catch |err| {
        std.log.err("Could not update lights buffer for cloud render: {}", .{err});
    };

    const compute_push_constants = CloudDensityPushConstant {
        .inv_view_projection_matrix = zm.inverse(zm.mul(camera.transform.generate_view_matrix(), camera.generate_perspective_matrix(eng.get().gfx.swapchain_aspect()))),
    };

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .fragment_shader = true, },
        .dst_stage = .{ .compute_shader = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.camera_lighting_grid_image,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
            },
        }
    });
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .late_fragment_tests = true, },
        .dst_stage = .{ .compute_shader = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = eng.get().gfx.default.depth_image,
                .src_access_mask = .{ .depth_stencil_attachment_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
                .old_layout = .DepthStencilAttachmentOptimal,
                .new_layout = .ShaderReadOnlyOptimal,
            },
        }
    });

    cmd.cmd_bind_compute_pipeline(self.compute_pipeline);
    cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.compute_descriptor_set } });
    cmd.cmd_push_constants(.{ .data = std.mem.asBytes(&compute_push_constants), .offset = 0, .shader_stages = .{ .Compute = true, } });
    cmd.cmd_dispatch(.{ .group_count_x = CAMERA_LIGHTING_GRID_IMAGE_SIZE[0], .group_count_y = CAMERA_LIGHTING_GRID_IMAGE_SIZE[1], .group_count_z = CAMERA_LIGHTING_GRID_IMAGE_SIZE[2], });

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .fragment_shader = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.camera_lighting_grid_image,
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

        const render_push_constants = RenderPushConstant {
            .inv_view_projection_matrix = compute_push_constants.inv_view_projection_matrix,
        };

        cmd.cmd_bind_graphics_pipeline(self.render_pipeline);
        cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.render_descriptor_set, }, });
        cmd.cmd_push_constants(.{ .data = std.mem.asBytes(&render_push_constants), .offset = 0, .shader_stages = .{ .Pixel = true, } });
        cmd.cmd_draw(.{ .vertex_count = 6, });
    }

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .early_fragment_tests = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = eng.get().gfx.default.depth_image,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .depth_stencil_attachment_write = true, },
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .DepthStencilAttachmentOptimal,
            },
        }
    });
}
