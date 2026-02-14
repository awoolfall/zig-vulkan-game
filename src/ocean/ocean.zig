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
const MAP_LENGTH_M = 256;
const COMPUTE_GROUP_COUNT: comptime_int = @divExact(N, 8);

const ShaderPath = "../../src/ocean/ocean_render.slang";
const CLIPMAP_QUAD_COUNT = 127;

const MAX_SHALLOW_SPOTS = 4;

const NUM_OCEAN_SPECTRUM_LODS = 4;

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
    model_matrix: zm.Mat,
    camera_position: zm.F32x4,

    spectrum_image_size: f32,
    map_length_m: f32,
    map_height_scale: f32,

    clipmap_level: f32,
};

const ShallowSpot = extern struct {
    point_0: [2]f32 = .{0.0, 0.0},
    point_1: [2]f32 = .{0.0, 0.0},
    inner_distance: f32 = 0.0,
    outer_distance: f32 = 0.0,

    _pad: [2]f32 = .{0.0, 0.0},
};

pub const OceanSettings = struct {
    amplitude: f32,
    wind: [2]f32,
};

current_settings: OceanSettings,

clipmap_mesh: ClipmapMesh,

gaussian_random_image: gfx.Image.Ref,
gaussian_random_view: gfx.ImageView.Ref,

h0_tilde_image: gfx.Image.Ref,
h0_tilde_view: [NUM_OCEAN_SPECTRUM_LODS]gfx.ImageView.Ref,

displacement_image: gfx.Image.Ref,
displacement_views: [NUM_OCEAN_SPECTRUM_LODS][2]gfx.ImageView.Ref,

slope_jacobian_image: gfx.Image.Ref,
slope_jacobian_views: [NUM_OCEAN_SPECTRUM_LODS][2]gfx.ImageView.Ref,

fft_processing_sj_image: gfx.Image.Ref,
fft_processing_sj_views: [NUM_OCEAN_SPECTRUM_LODS][2]gfx.ImageView.Ref,

fft_processing_d_image: gfx.Image.Ref,
fft_processing_d_views: [NUM_OCEAN_SPECTRUM_LODS][2]gfx.ImageView.Ref,

fft_descriptor_layout: gfx.DescriptorLayout.Ref,
fft_descriptor_pool: gfx.DescriptorPool.Ref,

fft_descriptor_sets_hs: [NUM_OCEAN_SPECTRUM_LODS][2]gfx.DescriptorSet.Ref,
fft_descriptor_sets_d: [NUM_OCEAN_SPECTRUM_LODS][2]gfx.DescriptorSet.Ref,

fft_horizontal_pipeline: gfx.ComputePipeline.Ref,
fft_vertical_pipeline: gfx.ComputePipeline.Ref,

h0_descriptor_layout: gfx.DescriptorLayout.Ref,
h0_descriptor_pool: gfx.DescriptorPool.Ref,
h0_descriptor_set: [NUM_OCEAN_SPECTRUM_LODS]gfx.DescriptorSet.Ref,

h0_pipeline: gfx.ComputePipeline.Ref,

spectrum_descriptor_layout: gfx.DescriptorLayout.Ref,
spectrum_descriptor_pool: gfx.DescriptorPool.Ref,
spectrum_descriptor_set: [NUM_OCEAN_SPECTRUM_LODS]gfx.DescriptorSet.Ref,

spectrum_pipeline: gfx.ComputePipeline.Ref,

jacobian_descriptor_layout: gfx.DescriptorLayout.Ref,
jacobian_descriptor_pool: gfx.DescriptorPool.Ref,
jacobian_descriptor_set: [NUM_OCEAN_SPECTRUM_LODS]gfx.DescriptorSet.Ref,

jacobian_pipeline: gfx.ComputePipeline.Ref,

render_lights_buffer: gfx.Buffer.Ref,
render_shallow_spots_buffer: gfx.Buffer.Ref,

render_shallow_spots_list: std.ArrayList(ShallowSpot),

render_displacement_view: gfx.ImageView.Ref,
render_slope_jacobian_view: gfx.ImageView.Ref,

render_descriptor_layout: gfx.DescriptorLayout.Ref,
render_descriptor_pool: gfx.DescriptorPool.Ref,
render_descriptor_set: gfx.DescriptorSet.Ref,

render_render_pass: gfx.RenderPass.Ref,
render_framebuffer: gfx.FrameBuffer.Ref,
render_pipeline: gfx.GraphicsPipeline.Ref,

render_sampler: gfx.Sampler.Ref,
render_shader_file_watcher: FileWatcher,

time: f32 = 1000.0,
time_scale: f32 = 1.0,

pub fn deinit(self: *Self) void {
    self.clipmap_mesh.deinit();

    self.render_displacement_view.deinit();
    self.render_slope_jacobian_view.deinit();

    self.gaussian_random_view.deinit();
    self.gaussian_random_image.deinit();

    for (self.h0_tilde_view) |view| {
        view.deinit();
    }
    self.h0_tilde_image.deinit();

    for (self.slope_jacobian_views) |views| {
        views[0].deinit();
        views[1].deinit();
    }
    self.slope_jacobian_image.deinit();

    for (self.displacement_views) |views| {
        views[0].deinit();
        views[1].deinit();
    }
    self.displacement_image.deinit();

    for (self.fft_processing_sj_views) |views| {
        views[0].deinit();
        views[1].deinit();
    }
    self.fft_processing_sj_image.deinit();

    for (self.fft_processing_d_views) |views| {
        views[0].deinit();
        views[1].deinit();
    }
    self.fft_processing_d_image.deinit();

    self.fft_horizontal_pipeline.deinit();
    self.fft_vertical_pipeline.deinit();

    for (self.fft_descriptor_sets_hs) |sets| {
        sets[0].deinit();
        sets[1].deinit();
    }

    for (self.fft_descriptor_sets_d) |sets| {
        sets[0].deinit();
        sets[1].deinit();
    }

    self.fft_descriptor_pool.deinit();
    self.fft_descriptor_layout.deinit();

    self.h0_pipeline.deinit();

    for (self.h0_descriptor_set) |set| {
        set.deinit();
    }
    self.h0_descriptor_pool.deinit();
    self.h0_descriptor_layout.deinit();

    self.spectrum_pipeline.deinit();

    for (self.spectrum_descriptor_set) |set| {
        set.deinit();
    }
    self.spectrum_descriptor_pool.deinit();
    self.spectrum_descriptor_layout.deinit();

    self.jacobian_pipeline.deinit();

    for (self.jacobian_descriptor_set) |set| {
        set.deinit();
    }
    self.jacobian_descriptor_pool.deinit();
    self.jacobian_descriptor_layout.deinit();
        
    self.render_descriptor_set.deinit();
    self.render_descriptor_pool.deinit();
    self.render_descriptor_layout.deinit();

    self.render_lights_buffer.deinit();
    self.render_shallow_spots_buffer.deinit();

    self.render_shallow_spots_list.deinit(eng.get().general_allocator);

    self.render_pipeline.deinit();
    self.render_framebuffer.deinit();
    self.render_render_pass.deinit();

    self.render_sampler.deinit();
    self.render_shader_file_watcher.deinit();
}

pub fn init() !Self {
    const alloc = eng.get().general_allocator;
    
    var arena_alloc = std.heap.ArenaAllocator.init(eng.get().frame_allocator);
    defer arena_alloc.deinit();

    const arena = arena_alloc.allocator();

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
            .array_length = NUM_OCEAN_SPECTRUM_LODS,
            .dst_layout = .ShaderReadOnlyOptimal,
            .usage_flags = .{ .ShaderResource = true, .StorageResource = true, },
            .access_flags = .{ .GpuWrite = true, },
        },
        null
    );
    errdefer h0_tilde_image.deinit();

    var h0_tilde_image_views = try std.ArrayList(gfx.ImageView.Ref).initCapacity(arena, NUM_OCEAN_SPECTRUM_LODS);
    defer h0_tilde_image_views.deinit(arena);
    errdefer for (h0_tilde_image_views.items) |view| { view.deinit(); };

    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        const view = try gfx.ImageView.init(.{
            .image = h0_tilde_image,
            .view_type = .ImageView2D,
            .array_layers = .{
                .base_array_layer = @intCast(layer),
                .array_layer_count = 1,
            },
        });
        errdefer view.deinit();

        try h0_tilde_image_views.append(arena, view);
    }

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
        .max_sets = NUM_OCEAN_SPECTRUM_LODS,
    });
    errdefer h0_descriptor_pool.deinit();

    var h0_tilde_image_sets = try std.ArrayList(gfx.DescriptorSet.Ref).initCapacity(arena, NUM_OCEAN_SPECTRUM_LODS);
    defer h0_tilde_image_sets.deinit(arena);
    errdefer for (h0_tilde_image_sets.items) |item| { item.deinit(); };

    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        const h0_descriptor_set = try (try h0_descriptor_pool.get()).allocate_set(.{ .layout = h0_descriptor_layout });
        errdefer h0_descriptor_set.deinit();

        try (try h0_descriptor_set.get()).update(.{
            .writes = &.{
                .{ .binding = 0, .data = .{ .ImageView = gaussian_random_image_view }, },
                .{ .binding = 1, .data = .{ .StorageImage = h0_tilde_image_views.items[layer] }, },
            },
        });

        try h0_tilde_image_sets.append(arena, h0_descriptor_set);
    }

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
    const displacement_image, var displacement_views = try init_fft_rw_image_and_view(N, arena);
    errdefer displacement_image.deinit();
    errdefer displacement_views.deinit(arena);
    errdefer for (displacement_views.items) |item| { item[0].deinit(); item[1].deinit(); };

    const slope_jacobian_image, var slope_jacobian_views = try init_fft_rw_image_and_view(N, arena);
    errdefer slope_jacobian_image.deinit();
    errdefer slope_jacobian_views.deinit(arena);
    errdefer for (slope_jacobian_views.items) |item| { item[0].deinit(); item[1].deinit(); };

    // fft processing images
    const fft_processing_sj_image, var fft_processing_sj_views = try init_fft_rw_image_and_view(N, arena);
    errdefer fft_processing_sj_image.deinit();
    errdefer fft_processing_sj_views.deinit(arena);
    errdefer for (fft_processing_sj_views.items) |item| { item[0].deinit(); item[1].deinit(); };

    const fft_processing_d_image, var fft_processing_d_views = try init_fft_rw_image_and_view(N, arena);
    errdefer fft_processing_d_image.deinit();
    errdefer fft_processing_d_views.deinit(arena);
    errdefer for (fft_processing_d_views.items) |item| { item[0].deinit(); item[1].deinit(); };

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

    const fft_descriptor_pool = try gfx.DescriptorPool.init(.{ .strategy = .{ .Layout = fft_descriptor_layout }, .max_sets = 4 * NUM_OCEAN_SPECTRUM_LODS, });
    errdefer fft_descriptor_pool.deinit();

    var fft_descriptor_sets_slope_jacobian_list = try std.ArrayList([2]gfx.DescriptorSet.Ref).initCapacity(arena, NUM_OCEAN_SPECTRUM_LODS);
    errdefer for (fft_descriptor_sets_slope_jacobian_list.items) |item| { item[0].deinit(); item[1].deinit(); };
    defer fft_descriptor_sets_slope_jacobian_list.deinit(arena);

    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        var fft_descriptor_sets_slope_jacobian: [2]gfx.DescriptorSet.Ref = undefined;

        fft_descriptor_sets_slope_jacobian[0] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
        errdefer fft_descriptor_sets_slope_jacobian[0].deinit();

        fft_descriptor_sets_slope_jacobian[1] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
        errdefer fft_descriptor_sets_slope_jacobian[1].deinit();

        try (try fft_descriptor_sets_slope_jacobian[0].get()).update(.{
            .writes = &.{
                .{ .binding = 0, .data = .{ .ImageView = slope_jacobian_views.items[layer][0] } },
                .{ .binding = 1, .data = .{ .ImageView = slope_jacobian_views.items[layer][1] } },
                .{ .binding = 2, .data = .{ .StorageImage = fft_processing_sj_views.items[layer][0] } },
                .{ .binding = 3, .data = .{ .StorageImage = fft_processing_sj_views.items[layer][1] } },
            },
        });

        try (try fft_descriptor_sets_slope_jacobian[1].get()).update(.{
            .writes = &.{
                .{ .binding = 0, .data = .{ .ImageView = fft_processing_sj_views.items[layer][0] } },
                .{ .binding = 1, .data = .{ .ImageView = fft_processing_sj_views.items[layer][1] } },
                .{ .binding = 2, .data = .{ .StorageImage = slope_jacobian_views.items[layer][0] } },
                .{ .binding = 3, .data = .{ .StorageImage = slope_jacobian_views.items[layer][1] } },
            },
        });

        try fft_descriptor_sets_slope_jacobian_list.append(arena, fft_descriptor_sets_slope_jacobian);
    }

    var fft_descriptor_sets_displacement_list = try std.ArrayList([2]gfx.DescriptorSet.Ref).initCapacity(arena, NUM_OCEAN_SPECTRUM_LODS);
    errdefer for (fft_descriptor_sets_displacement_list.items) |item| { item[0].deinit(); item[1].deinit(); };
    defer fft_descriptor_sets_displacement_list.deinit(arena);

    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        var fft_descriptor_sets_displacement: [2]gfx.DescriptorSet.Ref = undefined;

        fft_descriptor_sets_displacement[0] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
        errdefer fft_descriptor_sets_displacement[0].deinit();

        fft_descriptor_sets_displacement[1] = try (try fft_descriptor_pool.get()).allocate_set(.{ .layout = fft_descriptor_layout });
        errdefer fft_descriptor_sets_displacement[1].deinit();

        try (try fft_descriptor_sets_displacement[0].get()).update(.{
            .writes = &.{
                .{ .binding = 0, .data = .{ .ImageView = displacement_views.items[layer][0] } },
                .{ .binding = 1, .data = .{ .ImageView = displacement_views.items[layer][1] } },
                .{ .binding = 2, .data = .{ .StorageImage = fft_processing_d_views.items[layer][0] } },
                .{ .binding = 3, .data = .{ .StorageImage = fft_processing_d_views.items[layer][1] } },
            },
        });

        try (try fft_descriptor_sets_displacement[1].get()).update(.{
            .writes = &.{
                .{ .binding = 0, .data = .{ .ImageView = fft_processing_d_views.items[layer][0] } },
                .{ .binding = 1, .data = .{ .ImageView = fft_processing_d_views.items[layer][1] } },
                .{ .binding = 2, .data = .{ .StorageImage = displacement_views.items[layer][0] } },
                .{ .binding = 3, .data = .{ .StorageImage = displacement_views.items[layer][1] } },
            },
        });

        try fft_descriptor_sets_displacement_list.append(arena, fft_descriptor_sets_displacement);
    }

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

    // spectrum descriptors
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
        .max_sets = NUM_OCEAN_SPECTRUM_LODS,
    });
    errdefer spectrum_descriptor_pool.deinit();

    var spectrum_descriptor_sets_list = try std.ArrayList(gfx.DescriptorSet.Ref).initCapacity(arena, NUM_OCEAN_SPECTRUM_LODS);
    defer spectrum_descriptor_sets_list.deinit(arena);
    errdefer for (spectrum_descriptor_sets_list.items) |item| { item.deinit(); };

    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        const spectrum_descriptor_set = try (try spectrum_descriptor_pool.get()).allocate_set(.{ .layout = spectrum_descriptor_layout });
        errdefer spectrum_descriptor_set.deinit();

        try (try spectrum_descriptor_set.get()).update(.{
            .writes = &.{
                .{ .binding = 0, .data = .{ .ImageView = h0_tilde_image_views.items[layer] }, },
                .{ .binding = 1, .data = .{ .StorageImage = displacement_views.items[layer][0] }, },
                .{ .binding = 2, .data = .{ .StorageImage = displacement_views.items[layer][1] }, },
                .{ .binding = 3, .data = .{ .StorageImage = slope_jacobian_views.items[layer][0] }, },
                .{ .binding = 4, .data = .{ .StorageImage = slope_jacobian_views.items[layer][1] }, },
            },
        });
        
        try spectrum_descriptor_sets_list.append(arena, spectrum_descriptor_set);
    }

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
        .max_sets = NUM_OCEAN_SPECTRUM_LODS,
    });
    errdefer spectrum_descriptor_pool.deinit();

    var jacobian_descriptor_sets_list = try std.ArrayList(gfx.DescriptorSet.Ref).initCapacity(arena, NUM_OCEAN_SPECTRUM_LODS);
    defer jacobian_descriptor_sets_list.deinit(arena);
    errdefer for (jacobian_descriptor_sets_list.items) |item| { item.deinit(); };

    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        const jacobian_descriptor_set = try (try jacobian_descriptor_pool.get()).allocate_set(.{ .layout = jacobian_descriptor_layout });
        errdefer jacobian_descriptor_set.deinit();

        try (try jacobian_descriptor_set.get()).update(.{
            .writes = &.{
                .{ .binding = 0, .data = .{ .ImageView = displacement_views.items[layer][0] }, },
                .{ .binding = 1, .data = .{ .StorageImage = slope_jacobian_views.items[layer][0] }, },
            },
        });

        try jacobian_descriptor_sets_list.append(arena, jacobian_descriptor_set);
    }

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

    // render resources
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

    const shallow_spots_buffer = try gfx.Buffer.init(
        @sizeOf(ShallowSpot) * MAX_SHALLOW_SPOTS,
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer shallow_spots_buffer.deinit();

    const render_displacement_view = try gfx.ImageView.init(.{
        .image = displacement_image,
        .array_layers = .{
            .base_array_layer = 0,
            .array_layer_count = NUM_OCEAN_SPECTRUM_LODS,
        },
        .view_type = .ImageView2DArray,
    });
    errdefer render_displacement_view.deinit();

    const render_slope_jacobian_view = try gfx.ImageView.init(.{
        .image = slope_jacobian_image,
        .array_layers = .{
            .base_array_layer = 0,
            .array_layer_count = NUM_OCEAN_SPECTRUM_LODS,
        },
        .view_type = .ImageView2DArray,
    });
    errdefer render_slope_jacobian_view.deinit();

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
                .binding_type = .UniformBuffer,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Vertex = true, },
                .binding = 2,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 3,
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .binding = 4,
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
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .UniformBuffer = .{
                    .buffer = lights_buffer,
                } },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 1,
                .data = .{ .UniformBuffer = .{
                    .buffer = shallow_spots_buffer,
                } },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 2,
                .data = .{ .ImageView = render_displacement_view },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 3,
                .data = .{ .ImageView = render_slope_jacobian_view },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 4,
                .data = .{ .Sampler = sampler },
            },
        },
    });

    var shallow_spots_list = try std.ArrayList(ShallowSpot).initCapacity(eng.get().general_allocator, 32);
    errdefer shallow_spots_list.deinit(eng.get().general_allocator);

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
        .current_settings = undefined,
        
        .clipmap_mesh = clipmap_mesh,

        .gaussian_random_image = gaussian_random_image,
        .gaussian_random_view = gaussian_random_image_view,

        .h0_tilde_image = h0_tilde_image,
        .h0_tilde_view = h0_tilde_image_views.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .slope_jacobian_image = slope_jacobian_image,
        .slope_jacobian_views = slope_jacobian_views.items[0..NUM_OCEAN_SPECTRUM_LODS].*,
        
        .displacement_image = displacement_image,
        .displacement_views = displacement_views.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .fft_processing_sj_image = fft_processing_sj_image,
        .fft_processing_sj_views = fft_processing_sj_views.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .fft_processing_d_image = fft_processing_d_image,
        .fft_processing_d_views = fft_processing_d_views.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .fft_descriptor_layout = fft_descriptor_layout,
        .fft_descriptor_pool = fft_descriptor_pool,

        .fft_descriptor_sets_hs = fft_descriptor_sets_slope_jacobian_list.items[0..NUM_OCEAN_SPECTRUM_LODS].*,
        .fft_descriptor_sets_d = fft_descriptor_sets_displacement_list.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .fft_horizontal_pipeline = fft_horizontal_pipeline,
        .fft_vertical_pipeline = fft_vertical_pipeline,

        .h0_descriptor_layout = h0_descriptor_layout,
        .h0_descriptor_pool = h0_descriptor_pool,
        .h0_descriptor_set = h0_tilde_image_sets.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .h0_pipeline = h0_pipeline,

        .spectrum_descriptor_layout = spectrum_descriptor_layout,
        .spectrum_descriptor_pool = spectrum_descriptor_pool,
        .spectrum_descriptor_set = spectrum_descriptor_sets_list.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .spectrum_pipeline = spectrum_pipeline,

        .jacobian_descriptor_layout = jacobian_descriptor_layout,
        .jacobian_descriptor_pool = jacobian_descriptor_pool,
        .jacobian_descriptor_set = jacobian_descriptor_sets_list.items[0..NUM_OCEAN_SPECTRUM_LODS].*,

        .jacobian_pipeline = jacobian_pipeline,

        .render_displacement_view = render_displacement_view,
        .render_slope_jacobian_view = render_slope_jacobian_view,

        .render_descriptor_layout = render_descriptor_layout,
        .render_descriptor_pool = render_descriptor_pool,
        .render_descriptor_set = render_descriptor_set,

        .render_lights_buffer = lights_buffer,
        .render_shallow_spots_buffer = shallow_spots_buffer,

        .render_shallow_spots_list = shallow_spots_list,
        
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
        self.recreate_h0_image(&cmd, .{ .amplitude = 0.1, .wind = .{ 15.0, 0.0 } });
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

fn init_fft_rw_image_and_view(comptime side_length: u32, alloc: std.mem.Allocator) !struct { gfx.Image.Ref, std.ArrayList([2]gfx.ImageView.Ref) } {
    const image = try gfx.Image.init(
        .{
            .format = .Rgba32_Float,
            .width = side_length,
            .height = side_length,
            .array_length = NUM_OCEAN_SPECTRUM_LODS * 2,
            .dst_layout = .ShaderReadOnlyOptimal,
            .usage_flags = .{ .StorageResource = true, .ShaderResource = true, },
            .access_flags = .{ .GpuWrite = true, },
        },
        null
    );
    errdefer image.deinit();

    var image_views_list = try std.ArrayList([2]gfx.ImageView.Ref).initCapacity(alloc, NUM_OCEAN_SPECTRUM_LODS);
    errdefer image_views_list.deinit(alloc);
    errdefer for (image_views_list.items) |item| { item[0].deinit(); item[1].deinit(); };

    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        const view_r = try gfx.ImageView.init(.{ 
            .image = image, 
            .array_layers = .{ 
                .base_array_layer = @intCast(layer),
                .array_layer_count = 1,
            },
            .view_type = .ImageView2D
        });
        errdefer view_r.deinit();

        const view_i = try gfx.ImageView.init(.{ 
            .image = image, 
            .array_layers = .{ 
                .base_array_layer = @intCast(NUM_OCEAN_SPECTRUM_LODS + layer),
                .array_layer_count = 1,
            },
            .view_type = .ImageView2D
        });
        errdefer view_i.deinit();

        try image_views_list.append(alloc, .{ view_r, view_i });
    }

    return .{ image, image_views_list };
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
            .{ "NUM_OCEAN_LOD_LAYERS", std.fmt.comptimePrint("{}", .{ Self.NUM_OCEAN_SPECTRUM_LODS }) },
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
        .front_face = .Clockwise,
        .descriptor_set_layouts = &.{
            self.render_descriptor_layout,
        },
    });
    errdefer pipeline.deinit();

    return pipeline;
}

pub fn recreate_h0_image(self: *Self, cmd: *gfx.CommandBuffer, settings: OceanSettings) void {
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

    cmd.cmd_bind_compute_pipeline(self.h0_pipeline);
    inline for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        // dispatch h0 image generation
        cmd.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                self.h0_descriptor_set[layer],
            },
        });
        const h0_push_constant_data = H0PushConstantData {
            .map_length_m = @floatFromInt(calculate_layer_map_length(Self.MAP_LENGTH_M, layer)),
            .amplitude = settings.amplitude,
            .wind = settings.wind,
        };
        cmd.cmd_push_constants(.{
            .offset = 0,
            .shader_stages = .{ .Compute = true, },
            .data = @ptrCast(&h0_push_constant_data),
        });
        cmd.cmd_dispatch(.{ .group_count_x = COMPUTE_GROUP_COUNT, .group_count_y = COMPUTE_GROUP_COUNT, .group_count_z = 1, });
    }

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

    self.current_settings = settings;
}

pub fn push_shallow_spot(self: *Self, shallow_spot: ShallowSpot) void {
    self.render_shallow_spots_list.append(eng.get().general_allocator, shallow_spot) catch |err| {
        std.log.warn("Unable to add ocean shallow spot to list: {}", .{err});
    };
}

fn shallow_spots_sort_function(reference_point: zm.F32x4, spot_0: ShallowSpot, spot_1: ShallowSpot) bool {
    const spot_0_0 = zm.loadArr2(spot_0.point_0);
    const spot_0_1 = zm.loadArr2(spot_0.point_1);
    const spot_1_0 = zm.loadArr2(spot_1.point_0);
    const spot_1_1 = zm.loadArr2(spot_1.point_1);
    const spot_0_dist = @min(zm.length2(reference_point - spot_0_0)[0], zm.length2(reference_point - spot_0_1)[0]);
    const spot_1_dist = @min(zm.length2(reference_point - spot_1_0)[0], zm.length2(reference_point - spot_1_1)[0]);
    return spot_0_dist < spot_1_dist;
}

fn sort_shallow_spots(self: *Self, reference_point: [2]f32) void {
    std.mem.sort(ShallowSpot, self.render_shallow_spots_list.items, zm.loadArr2(reference_point), shallow_spots_sort_function);
}

fn calculate_layer_map_length(layer_0_map_length: usize, layer: usize) usize {
    return @divExact(layer_0_map_length, std.math.pow(usize, 2, layer));
}

pub fn update_images(self: *Self, cmd: *gfx.CommandBuffer) void {
    self.time += (eng.get().time.delta_time_f32() * self.time_scale);
    
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

    cmd.cmd_bind_compute_pipeline(self.spectrum_pipeline);
    inline for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        // dispatch spectrum image generation
        cmd.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                self.spectrum_descriptor_set[layer],
            },
        });
        const spectrum_push_constant_data = SpectrumPushConstantData {
            .map_length_m = @floatFromInt(calculate_layer_map_length(Self.MAP_LENGTH_M, layer)),
            .time = self.time,
        };
        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Compute = true, },
            .offset = 0,
            .data = std.mem.asBytes(&spectrum_push_constant_data),
        });
        cmd.cmd_dispatch(.{ .group_count_x = COMPUTE_GROUP_COUNT, .group_count_y = COMPUTE_GROUP_COUNT, .group_count_z = 1, });
    }

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

    cmd.cmd_bind_compute_pipeline(self.fft_horizontal_pipeline);
    for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        // dispatch horizontal stage FFTs
        cmd.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                self.fft_descriptor_sets_hs[layer][0],
            },
        });
        cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });

        cmd.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                self.fft_descriptor_sets_d[layer][0],
            },
        });
        cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });
    }
    
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

    cmd.cmd_bind_compute_pipeline(self.fft_vertical_pipeline);
    inline for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        // dispatch vertical stage FFTs
        cmd.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                self.fft_descriptor_sets_hs[layer][1],
            },
        });
        cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });

        cmd.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                self.fft_descriptor_sets_d[layer][1],
            },
        });
        cmd.cmd_dispatch(.{ .group_count_x = 1, .group_count_y = @intCast(N), .group_count_z = 1, });
    }

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

    cmd.cmd_bind_compute_pipeline(self.jacobian_pipeline);
    inline for (0..NUM_OCEAN_SPECTRUM_LODS) |layer| {
        // dispatch jacobian image generation
        cmd.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                self.jacobian_descriptor_set[layer],
            },
        });
        const jacobian_push_constant_data = JacobianPushConstantData {
            .map_length_m = @floatFromInt(calculate_layer_map_length(Self.MAP_LENGTH_M, layer)),
        };
        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Compute = true, },
            .offset = 0,
            .data = std.mem.asBytes(&jacobian_push_constant_data),
        });
        cmd.cmd_dispatch(.{ .group_count_x = COMPUTE_GROUP_COUNT, .group_count_y = COMPUTE_GROUP_COUNT, .group_count_z = 1, });
    }

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

    (blk: {
        const lights_buffer = self.render_lights_buffer.get() catch break :blk error.UnableToGetBuffer;
        const mapped_buffer = lights_buffer.map(.{ .write = .EveryFrame, }) catch break :blk error.UnableToMapBuffer;
        defer mapped_buffer.unmap();

        const data = mapped_buffer.data_array(StandardRenderer.LightsStruct, 16 * 16);
        standard_renderer.sort_lights(
            camera.transform.position
        );
        const max_lights = @min(StandardRenderer.MAX_LIGHTS, standard_renderer.lights.items.len);
        @memcpy(data[0].lights[0..max_lights], standard_renderer.lights.items[0..max_lights]);
    }) catch |err| {
        std.log.err("Could not update lights buffer for ocean render: {}", .{err});
    };

    (blk: {
        const buffer = self.render_shallow_spots_buffer.get() catch break :blk error.UnableToGetBuffer;
        const mapped_buffer = buffer.map(.{ .write = .EveryFrame, }) catch break :blk error.UnableToMapBuffer;
        defer mapped_buffer.unmap();

        const data = mapped_buffer.data_array(ShallowSpot, 4);
        @memset(data, .{});

        self.sort_shallow_spots(.{ camera.transform.position[0], camera.transform.position[2]});
        for (0..@min(self.render_shallow_spots_list.items.len, MAX_SHALLOW_SPOTS)) |i| {
            data[i] = self.render_shallow_spots_list.items[i];
        }
    }) catch |err| {
        std.log.err("Could not update shallow spots buffer for ocean render: {}", .{err});
    };

    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.render_descriptor_set,
        },
    });

    var push_constant_data = RenderPushConstantData {
        .view_projection_matrix = zm.mul(camera.transform.generate_view_matrix(), camera.generate_perspective_matrix(gfx.GfxState.get().swapchain_aspect())),
        .model_matrix = zm.identity(),
        .camera_position = camera.transform.position,

        .spectrum_image_size = Self.fN,
        .map_length_m = Self.MAP_LENGTH_M,
        .map_height_scale = 1.0,

        .clipmap_level = 0.0,
    };

    for (self.clipmap_mesh.middle_model_matrices) |mat| {
        push_constant_data.model_matrix = mat;

        // draw center quads
        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .index_count = self.clipmap_mesh.mxm_indices_cout,
        });
    }

    // draw trim around center level quads
    {
        // draw trim (pz px)
        push_constant_data.model_matrix = self.clipmap_mesh.interior_trim_locations.pz_px;

        // draw center level
        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .first_index = self.clipmap_mesh.interior_trim_indices_base,
            .index_count = self.clipmap_mesh.interior_trim_indices_count,
        });

        // draw trim (nz nx) (skipping first and last quad since that is drawn in pz px)
        push_constant_data.model_matrix = self.clipmap_mesh.interior_trim_locations.nz_nx;

        // draw center level
        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .first_index = self.clipmap_mesh.interior_trim_indices_base,
            .index_count = self.clipmap_mesh.interior_trim_indices_count,
        });
    }

    for (0..4) |level| {
        push_constant_data.clipmap_level = @floatFromInt(level);

        for (self.clipmap_mesh.mxm_model_matrices) |mat| {
            push_constant_data.model_matrix = mat;

            // draw mxm ring quads
            cmd.cmd_push_constants(.{
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .offset = 0,
                .data = std.mem.asBytes(&push_constant_data),
            });

            cmd.cmd_draw_indexed(.{
                .index_count = self.clipmap_mesh.mxm_indices_cout,
            });
        }

        for (self.clipmap_mesh.fixup_model_matrices) |mat| {
            push_constant_data.model_matrix = mat;

            // draw ring fixups
            cmd.cmd_push_constants(.{
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .offset = 0,
                .data = std.mem.asBytes(&push_constant_data),
            });

            cmd.cmd_draw_indexed(.{
                .index_count = self.clipmap_mesh.fixup_indices_count,
            });
        }

        // draw degenerate triangles
        push_constant_data.model_matrix = zm.identity();

        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .first_index = self.clipmap_mesh.degenerate_triangles_indices_base,
            .index_count = self.clipmap_mesh.degenerate_triangles_indices_count,
        });
    }

    // clear shallow spots ready for next frame
    self.render_shallow_spots_list.clearRetainingCapacity();
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
