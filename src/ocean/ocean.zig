const std = @import("std");
const eng = @import("engine");
const gfx = eng.gfx;
const zm = eng.zmath;
const FileWatcher = eng.assets.FileWatcher;
const StandardRenderer = @import("../render.zig");

const ClipmapMesh = @import("../terrain/clipmap.zig");

const Self = @This();

const N = 512;
const fN: comptime_float = @floatFromInt(N);
const MAP_LENGTH_M = fN / 2.0;
const COMPUTE_GROUP_COUNT: comptime_int = @divExact(N, 8);

const ShaderPath = "../../src/ocean/ocean_render.slang";
const CLIPMAP_QUAD_COUNT = 512;

const H0PushConstantData = extern struct {
    map_length_m: f32,
    amplitude: f32,
    wind: [2]f32,
};

const SpectrumPushConstantData = extern struct {
    map_length_m: f32,
    time: f32,
};

const JacobianPushConstantData = extern struct {
    map_length_m: f32,
};

const RenderPushConstantData = extern struct {
    view_projection_matrix: zm.Mat,
    camera_position: zm.F32x4,

    spectrum_image_size: f32,
    map_length_m: f32,
    map_height_scale: f32,

    clipmap_level: f32,
};

clipmap_mesh: ClipmapMesh,

gaussian_random_image: gfx.Image.Ref,
gaussian_random_view: gfx.ImageView.Ref,

h0_tilde_image: gfx.Image.Ref,
h0_tilde_view: gfx.ImageView.Ref,

displacement_image: gfx.Image.Ref,
displacement_views: [2]gfx.ImageView.Ref,

slope_jacobian_image: gfx.Image.Ref,
slope_jacobian_views: [2]gfx.ImageView.Ref,

fft_processing_sj_image: gfx.Image.Ref,
fft_processing_sj_views: [2]gfx.ImageView.Ref,

fft_processing_d_image: gfx.Image.Ref,
fft_processing_d_views: [2]gfx.ImageView.Ref,

fft_descriptor_layout: gfx.DescriptorLayout.Ref,
fft_descriptor_pool: gfx.DescriptorPool.Ref,

fft_descriptor_sets_hs: [2]gfx.DescriptorSet.Ref,
fft_descriptor_sets_d: [2]gfx.DescriptorSet.Ref,

fft_horizontal_pipeline: gfx.ComputePipeline.Ref,
fft_vertical_pipeline: gfx.ComputePipeline.Ref,

h0_descriptor_layout: gfx.DescriptorLayout.Ref,
h0_descriptor_pool: gfx.DescriptorPool.Ref,
h0_descriptor_set: gfx.DescriptorSet.Ref,

h0_pipeline: gfx.ComputePipeline.Ref,

spectrum_descriptor_layout: gfx.DescriptorLayout.Ref,
spectrum_descriptor_pool: gfx.DescriptorPool.Ref,
spectrum_descriptor_set: gfx.DescriptorSet.Ref,

spectrum_pipeline: gfx.ComputePipeline.Ref,

jacobian_descriptor_layout: gfx.DescriptorLayout.Ref,
jacobian_descriptor_pool: gfx.DescriptorPool.Ref,
jacobian_descriptor_set: gfx.DescriptorSet.Ref,

jacobian_pipeline: gfx.ComputePipeline.Ref,

render_lights_buffer: gfx.Buffer.Ref,

render_descriptor_layout: gfx.DescriptorLayout.Ref,
render_descriptor_pool: gfx.DescriptorPool.Ref,
render_descriptor_set: gfx.DescriptorSet.Ref,

render_render_pass: gfx.RenderPass.Ref,
render_framebuffer: gfx.FrameBuffer.Ref,
render_pipeline: gfx.GraphicsPipeline.Ref,

render_sampler: gfx.Sampler.Ref,
render_shader_file_watcher: FileWatcher,

pub fn deinit(self: *Self) void {
    self.clipmap_mesh.deinit();

    self.gaussian_random_view.deinit();
    self.gaussian_random_image.deinit();

    self.h0_tilde_view.deinit();
    self.h0_tilde_image.deinit();

    self.slope_jacobian_views[0].deinit();
    self.slope_jacobian_views[1].deinit();
    self.slope_jacobian_image.deinit();

    self.displacement_views[0].deinit();
    self.displacement_views[1].deinit();
    self.displacement_image.deinit();

    self.fft_processing_sj_views[0].deinit();
    self.fft_processing_sj_views[1].deinit();
    self.fft_processing_sj_image.deinit();

    self.fft_processing_d_views[0].deinit();
    self.fft_processing_d_views[1].deinit();
    self.fft_processing_d_image.deinit();

    self.fft_horizontal_pipeline.deinit();
    self.fft_vertical_pipeline.deinit();

    self.fft_descriptor_sets_hs[0].deinit();
    self.fft_descriptor_sets_hs[1].deinit();

    self.fft_descriptor_sets_d[0].deinit();
    self.fft_descriptor_sets_d[1].deinit();

    self.fft_descriptor_pool.deinit();
    self.fft_descriptor_layout.deinit();

    self.h0_pipeline.deinit();

    self.h0_descriptor_set.deinit();
    self.h0_descriptor_pool.deinit();
    self.h0_descriptor_layout.deinit();

    self.spectrum_pipeline.deinit();

    self.spectrum_descriptor_set.deinit();
    self.spectrum_descriptor_pool.deinit();
    self.spectrum_descriptor_layout.deinit();

    self.jacobian_pipeline.deinit();

    self.jacobian_descriptor_set.deinit();
    self.jacobian_descriptor_pool.deinit();
    self.jacobian_descriptor_layout.deinit();
        
    self.render_descriptor_set.deinit();
    self.render_descriptor_pool.deinit();
    self.render_descriptor_layout.deinit();

    self.render_lights_buffer.deinit();

    self.render_pipeline.deinit();
    self.render_framebuffer.deinit();
    self.render_render_pass.deinit();

    self.render_sampler.deinit();
    self.render_shader_file_watcher.deinit();
}

pub fn init() !Self {
    const alloc = eng.get().general_allocator;

    const clipmap_mesh = try ClipmapMesh.init(alloc, Self.CLIPMAP_QUAD_COUNT);
    errdefer clipmap_mesh.deinit();

    // gaussian random image
    const random_buffer = try generate_gaussian_random_image_data(alloc, N);
    defer alloc.free(random_buffer);

    const gaussian_random_image = try gfx.Image.init(
        .{
            .format = .Rg32_Float,
            .width = N,
            .height = N,
            .dst_layout = .ShaderReadOnlyOptimal,
            .usage_flags = .{ .ShaderResource = true, },
            .access_flags = .{},
        },
        std.mem.sliceAsBytes(random_buffer[0..])
    );
    errdefer gaussian_random_image.deinit();

    const gaussian_random_image_view = try gfx.ImageView.init(.{
        .image = gaussian_random_image,
        .view_type = .ImageView2D,
    });
    errdefer gaussian_random_image_view.deinit();

    // h0 tilde
    const h0_tilde_image = try gfx.Image.init(
        .{
            .format = .Rg32_Float,
            .width = N,
            .height = N,
            .dst_layout = .ShaderReadOnlyOptimal,
            .usage_flags = .{ .ShaderResource = true, .StorageResource = true, },
            .access_flags = .{ .GpuWrite = true, },
        },
        null
    );
    errdefer h0_tilde_image.deinit();

    const h0_tilde_image_view = try gfx.ImageView.init(.{
        .image = h0_tilde_image,
        .view_type = .ImageView2D,
    });
    errdefer h0_tilde_image_view.deinit();

    // h0 descritpors
    const h0_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 0,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 1,
                .binding_type = .StorageImage,
            },
        },
    });
    errdefer h0_descriptor_layout.deinit();

    const h0_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = h0_descriptor_layout },
        .max_sets = 1,
    });
    errdefer h0_descriptor_pool.deinit();

    const h0_descriptor_set = try (try h0_descriptor_pool.get()).allocate_set(.{ .layout = h0_descriptor_layout });
    errdefer h0_descriptor_set.deinit();

    try (try h0_descriptor_set.get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = gaussian_random_image_view }, },
            .{ .binding = 1, .data = .{ .StorageImage = h0_tilde_image_view }, },
        },
    });

    // h0 pipeline
    const h0_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("ocean_h0.slang"),
        .shader_entry_points = &.{
            "cs_main",
        },
        .preprocessor_macros = &.{
            .{ "TEX_SIZE", std.fmt.comptimePrint("{d}", .{Self.N}) },
        },
    });
    defer alloc.free(h0_spirv);

    const h0_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = h0_spirv,
    });
    defer h0_shader_module.deinit();

    const h0_pipeline = try gfx.ComputePipeline.init(.{
        .compute_shader = .{
            .module = &h0_shader_module,
            .entry_point = "cs_main",
        },
        .descriptor_set_layouts = &.{
            h0_descriptor_layout,
        },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(H0PushConstantData),
            }
        }
    });
    errdefer h0_pipeline.deinit();

    // spectrum images
    const displacement_image, const displacement_views = try init_fft_rw_image_and_view(N);
    errdefer displacement_image.deinit();
    errdefer displacement_views[0].deinit();
    errdefer displacement_views[1].deinit();

    const slope_jacobian_image, const slope_jacobian_views = try init_fft_rw_image_and_view(N);
    errdefer slope_jacobian_image.deinit();
    errdefer slope_jacobian_views[0].deinit();
    errdefer slope_jacobian_views[1].deinit();

    // fft processing images
    const fft_processing_sj_image, const fft_processing_sj_views = try init_fft_rw_image_and_view(N);
    errdefer fft_processing_sj_image.deinit();
    errdefer fft_processing_sj_views[0].deinit();
    errdefer fft_processing_sj_views[1].deinit();

    const fft_processing_d_image, const fft_processing_d_views = try init_fft_rw_image_and_view(N);
    errdefer fft_processing_d_image.deinit();
    errdefer fft_processing_d_views[0].deinit();
    errdefer fft_processing_d_views[1].deinit();

    // fft compute descriptors
    const fft_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 0,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 1,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 2,
                .binding_type = .StorageImage,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 3,
                .binding_type = .StorageImage,
            },
        },
    });
    errdefer fft_descriptor_layout.deinit();

    const fft_descriptor_pool = try gfx.DescriptorPool.init(.{ .strategy = .{ .Layout = fft_descriptor_layout }, .max_sets = 4, });
    errdefer fft_descriptor_pool.deinit();

    var fft_descriptor_sets_slope_jacobian: [2]gfx.DescriptorSet.Ref = undefined;

    fft_descriptor_sets_slope_jacobian[0] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
    errdefer fft_descriptor_sets_slope_jacobian[0].deinit();

    fft_descriptor_sets_slope_jacobian[1] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
    errdefer fft_descriptor_sets_slope_jacobian[1].deinit();

    try (try fft_descriptor_sets_slope_jacobian[0].get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = slope_jacobian_views[0] } },
            .{ .binding = 1, .data = .{ .ImageView = slope_jacobian_views[1] } },
            .{ .binding = 2, .data = .{ .StorageImage = fft_processing_sj_views[0] } },
            .{ .binding = 3, .data = .{ .StorageImage = fft_processing_sj_views[1] } },
        },
    });

    try (try fft_descriptor_sets_slope_jacobian[1].get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = fft_processing_sj_views[0] } },
            .{ .binding = 1, .data = .{ .ImageView = fft_processing_sj_views[1] } },
            .{ .binding = 2, .data = .{ .StorageImage = slope_jacobian_views[0] } },
            .{ .binding = 3, .data = .{ .StorageImage = slope_jacobian_views[1] } },
        },
    });

    var fft_descriptor_sets_displacement: [2]gfx.DescriptorSet.Ref = undefined;

    fft_descriptor_sets_displacement[0] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
    errdefer fft_descriptor_sets_displacement[0].deinit();

    fft_descriptor_sets_displacement[1] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
    errdefer fft_descriptor_sets_displacement[1].deinit();

    try (try fft_descriptor_sets_displacement[0].get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = displacement_views[0] } },
            .{ .binding = 1, .data = .{ .ImageView = displacement_views[1] } },
            .{ .binding = 2, .data = .{ .StorageImage = fft_processing_d_views[0] } },
            .{ .binding = 3, .data = .{ .StorageImage = fft_processing_d_views[1] } },
        },
    });

    try (try fft_descriptor_sets_displacement[1].get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = fft_processing_d_views[0] } },
            .{ .binding = 1, .data = .{ .ImageView = fft_processing_d_views[1] } },
            .{ .binding = 2, .data = .{ .StorageImage = displacement_views[0] } },
            .{ .binding = 3, .data = .{ .StorageImage = displacement_views[1] } },
        },
    });

    // fft compute pipelines
    const fft_horizontal_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("fftslm.slang"),
        .shader_entry_points = &.{
            "ButterflySLM",
        },
        .preprocessor_macros = &.{
            .{ "TRANSFORM_INVERSE", "1" },
            .{ "BUTTERFLY_COUNT", std.fmt.comptimePrint("{d}", .{std.math.log2(Self.N)}) },
            .{ "LENGTH", std.fmt.comptimePrint("{d}", .{Self.N}) },
            .{ "ROWPASS", "1" },
        },
    });
    defer alloc.free(fft_horizontal_spirv);

    const fft_horizontal_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = fft_horizontal_spirv,
    });
    defer fft_horizontal_shader_module.deinit();

    const fft_vertical_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("fftslm.slang"),
        .shader_entry_points = &.{
            "ButterflySLM",
        },
        .preprocessor_macros = &.{
            .{ "TRANSFORM_INVERSE", "1" },
            .{ "BUTTERFLY_COUNT", std.fmt.comptimePrint("{d}", .{std.math.log2(Self.N)}) },
            .{ "LENGTH", std.fmt.comptimePrint("{d}", .{Self.N}) },
            .{ "COLPASS", "1" },
        },
    });
    defer alloc.free(fft_vertical_spirv);

    const fft_vertical_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = fft_vertical_spirv,
    });
    defer fft_vertical_shader_module.deinit();

    const fft_horizontal_pipeline = try gfx.ComputePipeline.init(.{
        .compute_shader = .{
            .module = &fft_horizontal_shader_module,
            .entry_point = "ButterflySLM",
        },
        .descriptor_set_layouts = &.{
            fft_descriptor_layout,
        },
    });
    errdefer fft_horizontal_pipeline.deinit();

    const fft_vertical_pipeline = try gfx.ComputePipeline.init(.{
        .compute_shader = .{
            .module = &fft_vertical_shader_module,
            .entry_point = "ButterflySLM",
        },
        .descriptor_set_layouts = &.{
            fft_descriptor_layout,
        },
    });
    errdefer fft_vertical_pipeline.deinit();

    // spectrum descritpors
    const spectrum_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 0,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 1,
                .binding_type = .StorageImage,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 2,
                .binding_type = .StorageImage,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 3,
                .binding_type = .StorageImage,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 4,
                .binding_type = .StorageImage,
            },
        },
    });
    errdefer spectrum_descriptor_layout.deinit();

    const spectrum_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = spectrum_descriptor_layout },
        .max_sets = 1,
    });
    errdefer spectrum_descriptor_pool.deinit();

    const spectrum_descriptor_set = try (try spectrum_descriptor_pool.get()).allocate_set(.{ .layout = spectrum_descriptor_layout });
    errdefer spectrum_descriptor_set.deinit();

    try (try spectrum_descriptor_set.get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = h0_tilde_image_view }, },
            .{ .binding = 1, .data = .{ .StorageImage = displacement_views[0] }, },
            .{ .binding = 2, .data = .{ .StorageImage = displacement_views[1] }, },
            .{ .binding = 3, .data = .{ .StorageImage = slope_jacobian_views[0] }, },
            .{ .binding = 4, .data = .{ .StorageImage = slope_jacobian_views[1] }, },
        },
    });

    // spectrum pipeline
    const spectrum_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("ocean_spectrum.slang"),
        .shader_entry_points = &.{
            "cs_main",
        },
        .preprocessor_macros = &.{
            .{ "TEX_SIZE", std.fmt.comptimePrint("{d}", .{Self.N}) },
        },
    });
    defer alloc.free(spectrum_spirv);

    const spectrum_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = spectrum_spirv,
    });
    defer spectrum_shader_module.deinit();

    const spectrum_pipeline = try gfx.ComputePipeline.init(.{
        .compute_shader = .{
            .module = &spectrum_shader_module,
            .entry_point = "cs_main",
        },
        .descriptor_set_layouts = &.{
            spectrum_descriptor_layout,
        },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(SpectrumPushConstantData),
            }
        }
    });
    errdefer spectrum_pipeline.deinit();

    // jacobian descritpors
    const jacobian_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 0,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 1,
                .binding_type = .StorageImage,
            },
        },
    });
    errdefer jacobian_descriptor_layout.deinit();

    const jacobian_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = jacobian_descriptor_layout },
        .max_sets = 1,
    });
    errdefer spectrum_descriptor_pool.deinit();

    const jacobian_descriptor_set = try (try jacobian_descriptor_pool.get()).allocate_set(.{ .layout = jacobian_descriptor_layout });
    errdefer jacobian_descriptor_set.deinit();

    try (try jacobian_descriptor_set.get()).update(.{
        .writes = &.{
            .{ .binding = 0, .data = .{ .ImageView = displacement_views[0] }, },
            .{ .binding = 1, .data = .{ .StorageImage = slope_jacobian_views[0] }, },
        },
    });

    // jacobian pipeline
    const jacobian_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("ocean_jacobian.slang"),
        .shader_entry_points = &.{
            "cs_main",
        },
        .preprocessor_macros = &.{
            .{ "TEX_SIZE", std.fmt.comptimePrint("{d}", .{Self.N}) },
        },
    });
    defer alloc.free(jacobian_spirv);

    const jacobian_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = jacobian_spirv,
    });
    defer jacobian_shader_module.deinit();

    const jacobian_pipeline = try gfx.ComputePipeline.init(.{
        .compute_shader = .{
            .module = &jacobian_shader_module,
            .entry_point = "cs_main",
        },
        .descriptor_set_layouts = &.{
            jacobian_descriptor_layout,
        },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(JacobianPushConstantData),
            }
        }
    });
    errdefer jacobian_pipeline.deinit();

    // render descriptors
    const render_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 0,
                .binding_type = .UniformBuffer,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Vertex = true, },
                .binding = 1,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 2,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
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

    const sampler = try gfx.Sampler.init(.{
        .filter_min_mag = .Linear,
        .filter_mip = .Linear,
        .border_mode = .Wrap,
    });
    errdefer sampler.deinit();

    const lights_buffer = try gfx.Buffer.init(
        @sizeOf(StandardRenderer.LightsStruct) * (16 * 16),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer lights_buffer.deinit();

    try (try render_descriptor_set.get()).update(.{
        .writes = &.{
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .UniformBuffer = .{
                    .buffer = lights_buffer,
                } },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 1,
                .data = .{ .ImageView = displacement_views[0] },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 2,
                .data = .{ .ImageView = slope_jacobian_views[0] },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 3,
                .data = .{ .Sampler = sampler },
            },
        },
    });

    // render render pass
    const attachments = &[_]gfx.AttachmentInfo {
        gfx.AttachmentInfo {
            .name = "colour",
            .format = gfx.GfxState.hdr_format,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .Simple,
        },
        gfx.AttachmentInfo {
            .name = "depth",
            .format = gfx.GfxState.depth_format,
            .initial_layout = .DepthStencilAttachmentOptimal,
            .final_layout = .DepthStencilAttachmentOptimal,
            .blend_type = .None,
        },
    };

    const render_pass = try gfx.RenderPass.init(.{
        .attachments = attachments,
        .subpasses = &.{
            gfx.SubpassInfo {
                .attachments = &.{ "colour" },
                .depth_attachment = "depth",
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
            .SwapchainDepth,
        },
    });
    errdefer framebuffer.deinit();

    // render shader file watcher
    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.ShaderPath });
    defer path.deinit();

    const path_resolved = try path.resolve_path(alloc);
    defer alloc.free(path_resolved);

    var shader_file_watcher = try FileWatcher.init(alloc, path_resolved, 1000);
    errdefer shader_file_watcher.deinit();

    var self = Self {
        .clipmap_mesh = clipmap_mesh,

        .gaussian_random_image = gaussian_random_image,
        .gaussian_random_view = gaussian_random_image_view,

        .h0_tilde_image = h0_tilde_image,
        .h0_tilde_view = h0_tilde_image_view,

        .slope_jacobian_image = slope_jacobian_image,
        .slope_jacobian_views = slope_jacobian_views,
        
        .displacement_image = displacement_image,
        .displacement_views = displacement_views,

        .fft_processing_sj_image = fft_processing_sj_image,
        .fft_processing_sj_views = fft_processing_sj_views,

        .fft_processing_d_image = fft_processing_d_image,
        .fft_processing_d_views = fft_processing_d_views,

        .fft_descriptor_layout = fft_descriptor_layout,
        .fft_descriptor_pool = fft_descriptor_pool,

        .fft_descriptor_sets_hs = fft_descriptor_sets_slope_jacobian,
        .fft_descriptor_sets_d = fft_descriptor_sets_displacement,

        .fft_horizontal_pipeline = fft_horizontal_pipeline,
        .fft_vertical_pipeline = fft_vertical_pipeline,

        .h0_descriptor_layout = h0_descriptor_layout,
        .h0_descriptor_pool = h0_descriptor_pool,
        .h0_descriptor_set = h0_descriptor_set,

        .h0_pipeline = h0_pipeline,

        .spectrum_descriptor_layout = spectrum_descriptor_layout,
        .spectrum_descriptor_pool = spectrum_descriptor_pool,
        .spectrum_descriptor_set = spectrum_descriptor_set,

        .spectrum_pipeline = spectrum_pipeline,

        .jacobian_descriptor_layout = jacobian_descriptor_layout,
        .jacobian_descriptor_pool = jacobian_descriptor_pool,
        .jacobian_descriptor_set = jacobian_descriptor_set,

        .jacobian_pipeline = jacobian_pipeline,

        .render_descriptor_layout = render_descriptor_layout,
        .render_descriptor_pool = render_descriptor_pool,
        .render_descriptor_set = render_descriptor_set,

        .render_lights_buffer = lights_buffer,
        
        .render_render_pass = render_pass,
        .render_framebuffer = framebuffer,
        .render_pipeline = undefined,

        .render_sampler = sampler,
        .render_shader_file_watcher = shader_file_watcher,
    };

    self.render_pipeline = try self.create_pipeline();
    errdefer self.render_pipeline.deinit();

    // fill initial h0 image
    {
        var pool = try gfx.CommandPool.init(.{ .queue_family = .Compute });
        defer pool.deinit();

        var cmd = try (try pool.get()).allocate_command_buffer(.{});
        defer cmd.deinit();

        try cmd.cmd_begin(.{ .one_time_submit = true, });
        self.recreate_h0_image(&cmd, 0.15, .{ 15.0, 0.0 });
        try cmd.cmd_end();

        var fence = try gfx.Fence.init(.{});
        defer fence.deinit();

        try gfx.GfxState.get().submit_command_buffer(.{
            .command_buffers = &.{ &cmd },
            .fence = fence,
        });

        try fence.wait();
    }

    return self;
}

fn init_fft_rw_image_and_view(comptime side_length: u32) !struct { gfx.Image.Ref, [2]gfx.ImageView.Ref } {
    const image = try gfx.Image.init(
        .{
            .format = .Rgba32_Float,
            .width = side_length,
            .height = side_length,
            .array_length = 2,
            .dst_layout = .ShaderReadOnlyOptimal,
            .usage_flags = .{ .StorageResource = true, .ShaderResource = true, },
            .access_flags = .{ .GpuWrite = true, },
        },
        null
    );
    errdefer image.deinit();

    const view_r = try gfx.ImageView.init(.{ 
        .image = image, 
        .array_layers = .{ 
            .base_array_layer = 0,
            .array_layer_count = 1,
        },
        .view_type = .ImageView2D
    });
    errdefer view_r.deinit();

    const view_i = try gfx.ImageView.init(.{ 
        .image = image, 
        .array_layers = .{ 
            .base_array_layer = 1,
            .array_layer_count = 1,
        },
        .view_type = .ImageView2D
    });
    errdefer view_i.deinit();

    return .{ image, .{ view_r, view_i } };
}

fn create_pipeline(self: *Self) !gfx.GraphicsPipeline.Ref {
    const alloc = eng.get().general_allocator;

    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.ShaderPath });
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
            .{ "CLIPMAP_QUAD_COUNT", std.fmt.comptimePrint("{}", .{ Self.CLIPMAP_QUAD_COUNT }) },
        }
    });
    defer alloc.free(shader_spirv);

    const shader_module = try gfx.ShaderModule.init(.{ .spirv_data = shader_spirv });
    defer shader_module.deinit();

    const vertex_input = try gfx.VertexInput.init(.{
        .bindings = &.{
            .{ .binding = 0, .stride = 12, .input_rate = .Vertex, },
        },
        .attributes = &.{
            .{ .name = "POS",           .location = 0, .binding = 0, .offset = 0,  .format = .F32x3, },
        },
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
        .depth_test = .{ .write = true, },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .offset = 0,
                .size = @sizeOf(RenderPushConstantData),
            },
        },
        .topology = .TriangleList,
        .rasterization_fill_mode = .Fill,
        .descriptor_set_layouts = &.{
            self.render_descriptor_layout,
        },
    });
    errdefer pipeline.deinit();

    return pipeline;
}

pub fn recreate_h0_image(self: *Self, cmd: *gfx.CommandBuffer, amplitude: f32, wind: [2]f32) void {
    // transition h0 from shader reading to compute destination
    cmd.cmd_pipeline_barrier(.{
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.h0_tilde_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
            },
        },
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .compute_shader = true, },
    });

    // dispatch h0 image generation
    cmd.cmd_bind_compute_pipeline(self.h0_pipeline);
    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.h0_descriptor_set,
        },
    });
    const h0_push_constant_data = H0PushConstantData {
        .map_length_m = Self.MAP_LENGTH_M,
        .amplitude = amplitude,
        .wind = wind,
    };
    cmd.cmd_push_constants(.{
        .offset = 0,
        .shader_stages = .{ .Compute = true, },
        .data = @ptrCast(&h0_push_constant_data),
    });
    cmd.cmd_dispatch(.{ .group_count_x = COMPUTE_GROUP_COUNT, .group_count_y = COMPUTE_GROUP_COUNT, .group_count_z = 1, });

    // transition h0 to shader reading from compute destination
    cmd.cmd_pipeline_barrier(.{
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.h0_tilde_image,
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
        },
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .compute_shader = true, },
    });
}

pub fn update_images(self: *Self, cmd: *gfx.CommandBuffer) void {
    // transition spectrum images from shader reading to compute destination
    cmd.cmd_pipeline_barrier(.{
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.displacement_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
            },
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.slope_jacobian_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
            },
        },
        .src_stage = .{ .vertex_shader = true, .fragment_shader = true, },
        .dst_stage = .{ .compute_shader = true, },
    });

    // dispatch spectrum image generation
    cmd.cmd_bind_compute_pipeline(self.spectrum_pipeline);
    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.spectrum_descriptor_set,
        },
    });
    const spectrum_push_constant_data = SpectrumPushConstantData {
        .map_length_m = Self.MAP_LENGTH_M,
        .time = @floatCast(eng.get().time.time_since_start_of_app()),
    };
    cmd.cmd_push_constants(.{
        .shader_stages = .{ .Compute = true, },
        .offset = 0,
        .data = std.mem.asBytes(&spectrum_push_constant_data),
    });
    cmd.cmd_dispatch(.{ .group_count_x = COMPUTE_GROUP_COUNT, .group_count_y = COMPUTE_GROUP_COUNT, .group_count_z = 1, });

    // transition images to perform first stage of FFTs on height/slope and displacement images
    cmd.cmd_pipeline_barrier(.{
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.slope_jacobian_image,
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.fft_processing_sj_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
            },
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.displacement_image,
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.fft_processing_d_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
            },
        },
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .compute_shader = true, },
    });

    // dispatch horizontal stage FFTs
    cmd.cmd_bind_compute_pipeline(self.fft_horizontal_pipeline);
    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.fft_descriptor_sets_hs[0],
        },
    });
    cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });

    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.fft_descriptor_sets_d[0],
        },
    });
    cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });
    
    // transition images to perform second stage of FFTs on height/slope and displacement images
    cmd.cmd_pipeline_barrier(.{
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.slope_jacobian_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
            },
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.fft_processing_sj_image,
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.displacement_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .shader_read = true, },
                .dst_access_mask = .{ .shader_write = true, },
            },
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.fft_processing_d_image,
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
        },
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .compute_shader = true, },
    });

    // dispatch vertical stage FFTs
    cmd.cmd_bind_compute_pipeline(self.fft_vertical_pipeline);
    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.fft_descriptor_sets_hs[1],
        },
    });
    cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });

    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.fft_descriptor_sets_d[1],
        },
    });
    cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });

    // transition displacement image ready for shader reading
    cmd.cmd_pipeline_barrier(.{
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.displacement_image,
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
        },
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .vertex_shader = true, .fragment_shader = true, },
    });

    // dispatch jacobian image generation
    cmd.cmd_bind_compute_pipeline(self.jacobian_pipeline);
    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.jacobian_descriptor_set,
        },
    });
    const jacobian_push_constant_data = JacobianPushConstantData {
        .map_length_m = Self.MAP_LENGTH_M,
    };
    cmd.cmd_push_constants(.{
        .shader_stages = .{ .Compute = true, },
        .offset = 0,
        .data = std.mem.asBytes(&jacobian_push_constant_data),
    });
    cmd.cmd_dispatch(.{ .group_count_x = COMPUTE_GROUP_COUNT, .group_count_y = COMPUTE_GROUP_COUNT, .group_count_z = 1, });

    // finally transition slope_jacobian image ready for shader reading
    cmd.cmd_pipeline_barrier(.{
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = self.slope_jacobian_image,
                .old_layout = .General,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .shader_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
        },
        .src_stage = .{ .compute_shader = true, },
        .dst_stage = .{ .vertex_shader = true, .fragment_shader = true, },
    });
}

pub fn render(self: *Self, standard_renderer: *StandardRenderer, camera: *const eng.camera.Camera, cmd: *gfx.CommandBuffer) void {
    if (self.render_shader_file_watcher.was_modified_since_last_check()) blk: {
        const new_pipeline = self.create_pipeline() catch |err| {
            std.log.warn("Unable to recreate ocean render pipeline: {}", .{err});
            break :blk;
        };

        self.render_pipeline.deinit();
        self.render_pipeline = new_pipeline;
        gfx.GfxState.get().flush();
    }
    
    cmd.cmd_begin_render_pass(.{
        .framebuffer = self.render_framebuffer,
        .render_pass = self.render_render_pass,
        .render_area = .full_screen_pixels(),
    });
    defer cmd.cmd_end_render_pass();
    
    cmd.cmd_bind_graphics_pipeline(self.render_pipeline);

    cmd.cmd_bind_vertex_buffers(.{
        .buffers = &.{
            .{ .buffer = self.clipmap_mesh.vertices_buffer, },
        },
    });
    cmd.cmd_bind_index_buffer(.{
        .buffer = self.clipmap_mesh.indices_buffer,
        .index_format = .U32,
    });

    blk: {
        const lights_buffer = self.render_lights_buffer.get() catch break :blk;
        const mapped_buffer = lights_buffer.map(.{ .write = .EveryFrame, }) catch break :blk;
        defer mapped_buffer.unmap();

        const data = mapped_buffer.data_array(StandardRenderer.LightsStruct, 16 * 16);
        standard_renderer.sort_lights(
            camera.transform.position
        );
        const max_lights = @min(StandardRenderer.MAX_LIGHTS, standard_renderer.lights.items.len);
        @memcpy(data[0].lights[0..max_lights], standard_renderer.lights.items[0..max_lights]);
        // for (0..16) |i| {
        //     for (0..16) |j| {
        //         standard_renderer.sort_lights(
        //             transform.position + (grid_origin_at_camera_pos + 
        //             zm.f32x4(@as(f32, @floatFromInt(i)) - 8.0, 0.0, @as(f32, @floatFromInt(j)) - 8.0, 0.0)) * zm.f32x4s(grid_size)
        //         );
        //         const max_lights = @min(StandardRenderer.MAX_LIGHTS, standard_renderer.lights.items.len);
        //         @memcpy(data[i + (16 * j)].lights[0..max_lights], standard_renderer.lights.items[0..max_lights]);
        //     }
        // }
    }

    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.render_descriptor_set,
        },
    });

    var push_constant_data = RenderPushConstantData {
        .view_projection_matrix = zm.mul(camera.transform.generate_view_matrix(), camera.generate_perspective_matrix(gfx.GfxState.get().swapchain_aspect())),
        .camera_position = camera.transform.position,

        .spectrum_image_size = Self.fN,
        .map_length_m = Self.MAP_LENGTH_M,
        .map_height_scale = 1.0,

        .clipmap_level = 1.0,
    };

    // draw center level
    cmd.cmd_push_constants(.{
        .shader_stages = .{ .Vertex = true, .Pixel = true, },
        .offset = 0,
        .data = std.mem.asBytes(&push_constant_data),
    });

    cmd.cmd_draw_indexed(.{
        .index_count = self.clipmap_mesh.full_ring_indices_count,
    });

    // draw clipmap levels
    const CLIPMAP_LEVELS = 4;

    for (0..CLIPMAP_LEVELS) |_| {
        push_constant_data.clipmap_level += 1.0;

        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .index_count = self.clipmap_mesh.outer_ring_indices_count,
        });
    }
}

fn generate_gaussian_random_image_data(alloc: std.mem.Allocator, comptime image_side_length: comptime_int) ![][2]f32 {
    const buffer = try alloc.alloc([2]f32, image_side_length * image_side_length);
    errdefer alloc.free(buffer);

    var default_prng = std.Random.DefaultPrng.init(@truncate(@as(u128, @intCast(std.time.nanoTimestamp()))));
    var rand = default_prng.random();

    for (0..image_side_length) |i| {
        for (0..image_side_length) |j| {
            buffer[i * image_side_length + j][0] = rand.floatNorm(f32);
            buffer[i * image_side_length + j][1] = rand.floatNorm(f32);
        }
    }

    return buffer;
}
