const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gfx = eng.gfx;
const FileWatcher = eng.assets.FileWatcher;

const SkyViewShaderUri    = "src:/atmosphere/atmosphere_sky_view.slang";

const CubemapShaderSrc = @embedFile("atmosphere_cubemap.slang");

// atmosphere_common.slang is prepended to file-watched shaders at compile time.
const AtmosphereCommonSrc = @embedFile("atmosphere_common.slang");

const TRANSMITTANCE_W: u32 = 256;
const TRANSMITTANCE_H: u32 = 64;
const MULTI_SCATTER_SIZE: u32 = 32;
const SKY_VIEW_W: u32 = 200;
const SKY_VIEW_H: u32 = 100;
const AERIAL_SIZE: [3]u32 = .{ 32, 32, 32 };
const CUBEMAP_FACE_SIZE: u32 = 256;

// GPU-side struct matching AtmosphereParams in the shaders (float4 for vec3 fields).
const AtmosphereParamsGPU = extern struct {
    rayleigh_scattering: zm.F32x4,  // xyz = sigma_s_R (km^-1), w = scale_height_km
    mie_params:          zm.F32x4,  // x = sigma_s_M, y = sigma_a_M, z = scale_height_km, w = phase_g
    ozone_absorption:    zm.F32x4,  // xyz = sigma_a_O (km^-1), w = 0
    ground_albedo:       zm.F32x4,  // xyz = rho, w = 0
    sun_irradiance:      zm.F32x4,  // xyz = E_sun, w = 0
    planet_radius_km:         f32,
    atmosphere_radius_km:     f32,
    aerial_km_per_slice:      f32,
    _pad:                     f32 = 0,
};

const SkyViewPushConstant = extern struct {
    sun_direction:        [3]f32,
    camera_altitude_km:   f32,
};

const AerialPushConstant = extern struct {
    inv_view_projection:  zm.Mat,
    sun_direction:        [3]f32,
    _pad0:                f32 = 0,
    camera_position_km:   [3]f32,
    _pad1:                f32 = 0,
};

const CubemapPushConstant = extern struct {
    sun_direction:       [3]f32,
    camera_altitude_km:  f32,
};

const SkyAerialPushConstant = extern struct {
    inv_view_projection:  zm.Mat,
    sun_direction:        [3]f32,
    _pad0:                f32 = 0,
    camera_position_km:   [3]f32,
    aerial_km_per_slice:  f32,
};

pub const AtmosphereSettings = struct {
    planet_radius_km:              f32 = 6360.0,
    atmosphere_radius_km:          f32 = 6460.0,
    rayleigh_scattering:    [3]f32 = .{ 5.802e-3, 13.558e-3, 33.1e-3 },
    rayleigh_scale_height_km:      f32 = 8.0,
    mie_scattering:                f32 = 3.996e-3,
    mie_absorption:                f32 = 4.40e-3,
    mie_scale_height_km:           f32 = 1.2,
    mie_phase_g:                   f32 = 0.8,
    ozone_absorption:       [3]f32 = .{ 0.650e-3, 1.881e-3, 0.085e-3 },
    ground_albedo:          [3]f32 = .{ 0.3, 0.3, 0.3 },
    sun_irradiance:         [3]f32 = .{ 20.0, 20.0, 20.0 },
    aerial_perspective_km_per_slice: f32 = 1.0,
};

current_settings: AtmosphereSettings,
params_buffer: gfx.Buffer.Ref,

transmittance_image: gfx.Image.Ref,
transmittance_view:  gfx.ImageView.Ref,
multi_scatter_image: gfx.Image.Ref,
multi_scatter_view:  gfx.ImageView.Ref,
sky_view_image:      gfx.Image.Ref,
sky_view_view:       gfx.ImageView.Ref,
aerial_image:        gfx.Image.Ref,
aerial_view:         gfx.ImageView.Ref,

aerial_perspective_lut_view: gfx.ImageView.Ref,

cubemap_image:        gfx.Image.Ref,
cubemap_storage_view: gfx.ImageView.Ref,
cubemap_sampler_view: gfx.ImageView.Ref,

cubemap_descriptor_layout: gfx.DescriptorLayout.Ref,
cubemap_descriptor_pool:   gfx.DescriptorPool.Ref,
cubemap_descriptor_set:    gfx.DescriptorSet.Ref,
cubemap_pipeline:          gfx.ComputePipeline.Ref,

lut_sampler: gfx.Sampler.Ref,

transmittance_descriptor_layout: gfx.DescriptorLayout.Ref,
transmittance_descriptor_pool:   gfx.DescriptorPool.Ref,
transmittance_descriptor_set:    gfx.DescriptorSet.Ref,
transmittance_pipeline:          gfx.ComputePipeline.Ref,

multi_scatter_descriptor_layout: gfx.DescriptorLayout.Ref,
multi_scatter_descriptor_pool:   gfx.DescriptorPool.Ref,
multi_scatter_descriptor_set:    gfx.DescriptorSet.Ref,
multi_scatter_pipeline:          gfx.ComputePipeline.Ref,

sky_view_descriptor_layout: gfx.DescriptorLayout.Ref,
sky_view_descriptor_pool:   gfx.DescriptorPool.Ref,
sky_view_descriptor_set:    gfx.DescriptorSet.Ref,
sky_view_pipeline:          gfx.ComputePipeline.Ref,
sky_view_shader_watcher:    FileWatcher,

aerial_descriptor_layout: gfx.DescriptorLayout.Ref,
aerial_descriptor_pool:   gfx.DescriptorPool.Ref,
aerial_descriptor_set:    gfx.DescriptorSet.Ref,
aerial_pipeline:          gfx.ComputePipeline.Ref,

sky_aerial_descriptor_layout: gfx.DescriptorLayout.Ref,
sky_aerial_descriptor_pool:   gfx.DescriptorPool.Ref,
sky_aerial_descriptor_set:    gfx.DescriptorSet.Ref,
sky_aerial_pipeline:          gfx.ComputePipeline.Ref,

pub fn deinit(self: *Self) void {
    self.transmittance_pipeline.deinit();
    self.transmittance_descriptor_set.deinit();
    self.transmittance_descriptor_pool.deinit();
    self.transmittance_descriptor_layout.deinit();

    self.multi_scatter_pipeline.deinit();
    self.multi_scatter_descriptor_set.deinit();
    self.multi_scatter_descriptor_pool.deinit();
    self.multi_scatter_descriptor_layout.deinit();

    self.sky_view_pipeline.deinit();
    self.sky_view_descriptor_set.deinit();
    self.sky_view_descriptor_pool.deinit();
    self.sky_view_descriptor_layout.deinit();
    self.sky_view_shader_watcher.deinit();

    self.aerial_pipeline.deinit();
    self.aerial_descriptor_set.deinit();
    self.aerial_descriptor_pool.deinit();
    self.aerial_descriptor_layout.deinit();

    self.cubemap_pipeline.deinit();
    self.cubemap_descriptor_set.deinit();
    self.cubemap_descriptor_pool.deinit();
    self.cubemap_descriptor_layout.deinit();

    self.sky_aerial_pipeline.deinit();
    self.sky_aerial_descriptor_set.deinit();
    self.sky_aerial_descriptor_pool.deinit();
    self.sky_aerial_descriptor_layout.deinit();

    self.lut_sampler.deinit();

    self.cubemap_sampler_view.deinit();
    self.cubemap_storage_view.deinit();
    self.cubemap_image.deinit();

    self.aerial_view.deinit();
    self.aerial_image.deinit();
    self.sky_view_view.deinit();
    self.sky_view_image.deinit();
    self.multi_scatter_view.deinit();
    self.multi_scatter_image.deinit();
    self.transmittance_view.deinit();
    self.transmittance_image.deinit();

    self.params_buffer.deinit();
}

pub fn init(settings: AtmosphereSettings) !Self {
    const alloc = eng.get().general_allocator;

    // Params buffer
    const params_buffer = try gfx.Buffer.init(
        @sizeOf(AtmosphereParamsGPU),
        .{ .ConstantBuffer = true },
        .{ .CpuWrite = true },
    );
    errdefer params_buffer.deinit();
    try upload_params(params_buffer, settings);

    // LUT images
    const transmittance_image = try gfx.Image.init(.{
        .match_swapchain_extent = false,
        .width = TRANSMITTANCE_W, .height = TRANSMITTANCE_H,
        .format = .Rgba16_Float,
        .usage_flags = .{ .StorageResource = true, .ShaderResource = true },
        .access_flags = .{ .GpuWrite = true },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer transmittance_image.deinit();

    const transmittance_view = try gfx.ImageView.init(.{ .image = transmittance_image, .view_type = .ImageView2D });
    errdefer transmittance_view.deinit();

    const multi_scatter_image = try gfx.Image.init(.{
        .match_swapchain_extent = false,
        .width = MULTI_SCATTER_SIZE, .height = MULTI_SCATTER_SIZE,
        .format = .Rgba16_Float,
        .usage_flags = .{ .StorageResource = true, .ShaderResource = true },
        .access_flags = .{ .GpuWrite = true },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer multi_scatter_image.deinit();

    const multi_scatter_view = try gfx.ImageView.init(.{ .image = multi_scatter_image, .view_type = .ImageView2D });
    errdefer multi_scatter_view.deinit();

    const sky_view_image = try gfx.Image.init(.{
        .match_swapchain_extent = false,
        .width = SKY_VIEW_W, .height = SKY_VIEW_H,
        .format = .Rgba16_Float,
        .usage_flags = .{ .StorageResource = true, .ShaderResource = true },
        .access_flags = .{ .GpuWrite = true },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer sky_view_image.deinit();

    const sky_view_view = try gfx.ImageView.init(.{ .image = sky_view_image, .view_type = .ImageView2D });
    errdefer sky_view_view.deinit();

    const aerial_image = try gfx.Image.init(.{
        .match_swapchain_extent = false,
        .width = AERIAL_SIZE[0], .height = AERIAL_SIZE[1], .depth = AERIAL_SIZE[2],
        .format = .Rgba16_Float,
        .usage_flags = .{ .StorageResource = true, .ShaderResource = true },
        .access_flags = .{ .GpuWrite = true },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer aerial_image.deinit();

    const aerial_view = try gfx.ImageView.init(.{ .image = aerial_image, .view_type = .ImageView3D });
    errdefer aerial_view.deinit();

    const cubemap_image = try gfx.Image.init(.{
        .match_swapchain_extent = false,
        .width = CUBEMAP_FACE_SIZE, .height = CUBEMAP_FACE_SIZE,
        .array_length = 6,
        .is_cube = true,
        .format = .Rgba16_Float,
        .usage_flags = .{ .StorageResource = true, .ShaderResource = true },
        .access_flags = .{ .GpuWrite = true },
        .dst_layout = .ShaderReadOnlyOptimal,
    }, null);
    errdefer cubemap_image.deinit();

    // 2D array view for compute UAV writes (Vulkan forbids cube views as storage images)
    const cubemap_storage_view = try gfx.ImageView.init(.{
        .image = cubemap_image,
        .view_type = .ImageView2DArray,
    });
    errdefer cubemap_storage_view.deinit();

    // Cube view for sampling in later pipeline stages
    const cubemap_sampler_view = try gfx.ImageView.init(.{
        .image = cubemap_image,
        .view_type = .ImageViewCube,
    });
    errdefer cubemap_sampler_view.deinit();

    // Sampler: linear clamp
    const lut_sampler = try gfx.Sampler.init(.{
        .filter_min_mag = .Linear,
        .filter_mip = .Linear,
        .border_mode = .Clamp,
    });
    errdefer lut_sampler.deinit();

    // --- Transmittance descriptor layout ---
    const transmittance_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            .{ .shader_stages = .{ .Compute = true }, .binding = 0, .binding_type = .UniformBuffer },
            .{ .shader_stages = .{ .Compute = true }, .binding = 1, .binding_type = .StorageImage },
        },
    });
    errdefer transmittance_descriptor_layout.deinit();

    const transmittance_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = transmittance_descriptor_layout }, .max_sets = 1,
    });
    errdefer transmittance_descriptor_pool.deinit();

    const transmittance_descriptor_set = try (try transmittance_descriptor_pool.get()).allocate_set(.{ .layout = transmittance_descriptor_layout });
    errdefer transmittance_descriptor_set.deinit();

    try (try transmittance_descriptor_set.get()).update(.{ .writes = &.{
        .{ .binding = 0, .data = .{ .UniformBuffer = .{ .buffer = params_buffer } } },
        .{ .binding = 1, .data = .{ .StorageImage = transmittance_view } },
    }});

    // --- Multi-scatter descriptor layout ---
    const multi_scatter_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            .{ .shader_stages = .{ .Compute = true }, .binding = 0, .binding_type = .UniformBuffer },
            .{ .shader_stages = .{ .Compute = true }, .binding = 1, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 2, .binding_type = .Sampler },
            .{ .shader_stages = .{ .Compute = true }, .binding = 3, .binding_type = .StorageImage },
        },
    });
    errdefer multi_scatter_descriptor_layout.deinit();

    const multi_scatter_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = multi_scatter_descriptor_layout }, .max_sets = 1,
    });
    errdefer multi_scatter_descriptor_pool.deinit();

    const multi_scatter_descriptor_set = try (try multi_scatter_descriptor_pool.get()).allocate_set(.{ .layout = multi_scatter_descriptor_layout });
    errdefer multi_scatter_descriptor_set.deinit();

    try (try multi_scatter_descriptor_set.get()).update(.{ .writes = &.{
        .{ .binding = 0, .data = .{ .UniformBuffer = .{ .buffer = params_buffer } } },
        .{ .binding = 1, .data = .{ .ImageView = transmittance_view } },
        .{ .binding = 2, .data = .{ .Sampler = lut_sampler } },
        .{ .binding = 3, .data = .{ .StorageImage = multi_scatter_view } },
    }});

    // --- Sky-view descriptor layout ---
    const sky_view_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            .{ .shader_stages = .{ .Compute = true }, .binding = 0, .binding_type = .UniformBuffer },
            .{ .shader_stages = .{ .Compute = true }, .binding = 1, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 2, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 3, .binding_type = .Sampler },
            .{ .shader_stages = .{ .Compute = true }, .binding = 4, .binding_type = .StorageImage },
        },
    });
    errdefer sky_view_descriptor_layout.deinit();

    const sky_view_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = sky_view_descriptor_layout }, .max_sets = 1,
    });
    errdefer sky_view_descriptor_pool.deinit();

    const sky_view_descriptor_set = try (try sky_view_descriptor_pool.get()).allocate_set(.{ .layout = sky_view_descriptor_layout });
    errdefer sky_view_descriptor_set.deinit();

    try (try sky_view_descriptor_set.get()).update(.{ .writes = &.{
        .{ .binding = 0, .data = .{ .UniformBuffer = .{ .buffer = params_buffer } } },
        .{ .binding = 1, .data = .{ .ImageView = transmittance_view } },
        .{ .binding = 2, .data = .{ .ImageView = multi_scatter_view } },
        .{ .binding = 3, .data = .{ .Sampler = lut_sampler } },
        .{ .binding = 4, .data = .{ .StorageImage = sky_view_view } },
    }});

    // --- Aerial perspective descriptor layout ---
    const aerial_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            .{ .shader_stages = .{ .Compute = true }, .binding = 0, .binding_type = .UniformBuffer },
            .{ .shader_stages = .{ .Compute = true }, .binding = 1, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 2, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 3, .binding_type = .Sampler },
            .{ .shader_stages = .{ .Compute = true }, .binding = 4, .binding_type = .StorageImage },
        },
    });
    errdefer aerial_descriptor_layout.deinit();

    const aerial_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = aerial_descriptor_layout }, .max_sets = 1,
    });
    errdefer aerial_descriptor_pool.deinit();

    const aerial_descriptor_set = try (try aerial_descriptor_pool.get()).allocate_set(.{ .layout = aerial_descriptor_layout });
    errdefer aerial_descriptor_set.deinit();

    try (try aerial_descriptor_set.get()).update(.{ .writes = &.{
        .{ .binding = 0, .data = .{ .UniformBuffer = .{ .buffer = params_buffer } } },
        .{ .binding = 1, .data = .{ .ImageView = transmittance_view } },
        .{ .binding = 2, .data = .{ .ImageView = multi_scatter_view } },
        .{ .binding = 3, .data = .{ .Sampler = lut_sampler } },
        .{ .binding = 4, .data = .{ .StorageImage = aerial_view } },
    }});

    // --- Cubemap descriptor layout ---
    const cubemap_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            .{ .shader_stages = .{ .Compute = true }, .binding = 0, .binding_type = .UniformBuffer },
            .{ .shader_stages = .{ .Compute = true }, .binding = 1, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 2, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 3, .binding_type = .Sampler },
            .{ .shader_stages = .{ .Compute = true }, .binding = 4, .binding_type = .StorageImage },
        },
    });
    errdefer cubemap_descriptor_layout.deinit();

    const cubemap_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = cubemap_descriptor_layout }, .max_sets = 1,
    });
    errdefer cubemap_descriptor_pool.deinit();

    const cubemap_descriptor_set = try (try cubemap_descriptor_pool.get()).allocate_set(.{ .layout = cubemap_descriptor_layout });
    errdefer cubemap_descriptor_set.deinit();

    try (try cubemap_descriptor_set.get()).update(.{ .writes = &.{
        .{ .binding = 0, .data = .{ .UniformBuffer = .{ .buffer = params_buffer } } },
        .{ .binding = 1, .data = .{ .ImageView = transmittance_view } },
        .{ .binding = 2, .data = .{ .ImageView = sky_view_view } },
        .{ .binding = 3, .data = .{ .Sampler = lut_sampler } },
        .{ .binding = 4, .data = .{ .StorageImage = cubemap_storage_view } },
    }});

    // --- Sky + aerial perspective combined descriptor layout ---
    const sky_aerial_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            .{ .shader_stages = .{ .Compute = true }, .binding = 0, .binding_type = .StorageImage },
            .{ .shader_stages = .{ .Compute = true }, .binding = 1, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 2, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 3, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 4, .binding_type = .ImageView },
            .{ .shader_stages = .{ .Compute = true }, .binding = 5, .binding_type = .UniformBuffer },
            .{ .shader_stages = .{ .Compute = true }, .binding = 6, .binding_type = .Sampler },
        },
    });
    errdefer sky_aerial_descriptor_layout.deinit();

    const sky_aerial_descriptor_pool = try gfx.DescriptorPool.init(.{
        .strategy = .{ .Layout = sky_aerial_descriptor_layout }, .max_sets = 1,
    });
    errdefer sky_aerial_descriptor_pool.deinit();

    const sky_aerial_descriptor_set = try (try sky_aerial_descriptor_pool.get()).allocate_set(.{ .layout = sky_aerial_descriptor_layout });
    errdefer sky_aerial_descriptor_set.deinit();

    try (try sky_aerial_descriptor_set.get()).update(.{ .writes = &.{
        .{ .binding = 0, .data = .{ .StorageImage = eng.get().gfx.default.hdr_image_view } },
        .{ .binding = 1, .data = .{ .ImageView    = eng.get().gfx.default.depth_view } },
        .{ .binding = 2, .data = .{ .ImageView    = aerial_view } },
        .{ .binding = 3, .data = .{ .ImageView    = sky_view_view } },
        .{ .binding = 4, .data = .{ .ImageView    = transmittance_view } },
        .{ .binding = 5, .data = .{ .UniformBuffer = .{ .buffer = params_buffer } } },
        .{ .binding = 6, .data = .{ .Sampler      = lut_sampler } },
    }});

    // Static LUT pipelines (embedded, no file watcher)
    const transmittance_pipeline = try create_transmittance_pipeline(transmittance_descriptor_layout);
    errdefer transmittance_pipeline.deinit();

    const multi_scatter_pipeline = try create_multi_scatter_pipeline(multi_scatter_descriptor_layout);
    errdefer multi_scatter_pipeline.deinit();

    const aerial_pipeline = try create_aerial_pipeline(aerial_descriptor_layout);
    errdefer aerial_pipeline.deinit();

    const sky_aerial_pipeline = try create_sky_aerial_pipeline(sky_aerial_descriptor_layout);
    errdefer sky_aerial_pipeline.deinit();

    const cubemap_pipeline = try create_cubemap_pipeline(cubemap_descriptor_layout);
    errdefer cubemap_pipeline.deinit();

    // File watchers for hot-reloaded shaders
    const sky_view_path = try eng.util.uri.resolve_file_uri(alloc, SkyViewShaderUri);
    defer alloc.free(sky_view_path);
    var sky_view_shader_watcher = try FileWatcher.init(alloc, sky_view_path, 1000);
    errdefer sky_view_shader_watcher.deinit();

    var self = Self {
        .current_settings = settings,
        .params_buffer = params_buffer,

        .transmittance_image = transmittance_image,
        .transmittance_view  = transmittance_view,
        .multi_scatter_image = multi_scatter_image,
        .multi_scatter_view  = multi_scatter_view,
        .sky_view_image      = sky_view_image,
        .sky_view_view       = sky_view_view,
        .aerial_image        = aerial_image,
        .aerial_view         = aerial_view,
        .aerial_perspective_lut_view = aerial_view,

        .lut_sampler = lut_sampler,

        .transmittance_descriptor_layout = transmittance_descriptor_layout,
        .transmittance_descriptor_pool   = transmittance_descriptor_pool,
        .transmittance_descriptor_set    = transmittance_descriptor_set,
        .transmittance_pipeline          = transmittance_pipeline,

        .multi_scatter_descriptor_layout = multi_scatter_descriptor_layout,
        .multi_scatter_descriptor_pool   = multi_scatter_descriptor_pool,
        .multi_scatter_descriptor_set    = multi_scatter_descriptor_set,
        .multi_scatter_pipeline          = multi_scatter_pipeline,

        .sky_view_descriptor_layout = sky_view_descriptor_layout,
        .sky_view_descriptor_pool   = sky_view_descriptor_pool,
        .sky_view_descriptor_set    = sky_view_descriptor_set,
        .sky_view_pipeline          = undefined,
        .sky_view_shader_watcher    = sky_view_shader_watcher,

        .aerial_descriptor_layout = aerial_descriptor_layout,
        .aerial_descriptor_pool   = aerial_descriptor_pool,
        .aerial_descriptor_set    = aerial_descriptor_set,
        .aerial_pipeline          = aerial_pipeline,

        .cubemap_image        = cubemap_image,
        .cubemap_storage_view = cubemap_storage_view,
        .cubemap_sampler_view = cubemap_sampler_view,
        .cubemap_descriptor_layout = cubemap_descriptor_layout,
        .cubemap_descriptor_pool   = cubemap_descriptor_pool,
        .cubemap_descriptor_set    = cubemap_descriptor_set,
        .cubemap_pipeline          = cubemap_pipeline,

        .sky_aerial_descriptor_layout = sky_aerial_descriptor_layout,
        .sky_aerial_descriptor_pool   = sky_aerial_descriptor_pool,
        .sky_aerial_descriptor_set    = sky_aerial_descriptor_set,
        .sky_aerial_pipeline          = sky_aerial_pipeline,
    };

    self.sky_view_pipeline = try self.create_sky_view_pipeline();
    errdefer self.sky_view_pipeline.deinit();

    // Compute static LUTs synchronously at init
    {
        var pool = try gfx.CommandPool.init(.{ .queue_family = .Compute });
        defer pool.deinit();

        var cmd = try (try pool.get()).allocate_command_buffer(.{});
        defer cmd.deinit();

        try cmd.cmd_begin(.{ .one_time_submit = true });
        self.recreate_static_luts(&cmd, settings);
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

fn upload_params(buffer: gfx.Buffer.Ref, settings: AtmosphereSettings) !void {
    const mapped = try (try buffer.get()).map(.{ .write = .Infrequent });
    defer mapped.unmap();

    const gpu_params = mapped.data(AtmosphereParamsGPU);
    gpu_params.* = AtmosphereParamsGPU {
        .rayleigh_scattering = zm.f32x4(
            settings.rayleigh_scattering[0],
            settings.rayleigh_scattering[1],
            settings.rayleigh_scattering[2],
            settings.rayleigh_scale_height_km,
        ),
        .mie_params = zm.f32x4(
            settings.mie_scattering,
            settings.mie_absorption,
            settings.mie_scale_height_km,
            settings.mie_phase_g,
        ),
        .ozone_absorption = zm.f32x4(
            settings.ozone_absorption[0],
            settings.ozone_absorption[1],
            settings.ozone_absorption[2],
            0,
        ),
        .ground_albedo = zm.f32x4(
            settings.ground_albedo[0],
            settings.ground_albedo[1],
            settings.ground_albedo[2],
            0,
        ),
        .sun_irradiance = zm.f32x4(
            settings.sun_irradiance[0],
            settings.sun_irradiance[1],
            settings.sun_irradiance[2],
            0,
        ),
        .planet_radius_km         = settings.planet_radius_km,
        .atmosphere_radius_km     = settings.atmosphere_radius_km,
        .aerial_km_per_slice      = settings.aerial_perspective_km_per_slice,
    };
}

pub fn recreate_static_luts(self: *Self, cmd: *gfx.CommandBuffer, settings: AtmosphereSettings) void {
    upload_params(self.params_buffer, settings) catch |err| {
        std.log.err("atmosphere: failed to upload params: {}", .{err});
    };
    self.current_settings = settings;

    // Transition LUTs to General for compute write
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .fragment_shader = true },
        .dst_stage = .{ .compute_shader = true },
        .image_barriers = &.{
            .{ .image = self.transmittance_image, .old_layout = .ShaderReadOnlyOptimal, .new_layout = .General,
               .src_access_mask = .{ .shader_read = true }, .dst_access_mask = .{ .shader_write = true } },
            .{ .image = self.multi_scatter_image, .old_layout = .ShaderReadOnlyOptimal, .new_layout = .General,
               .src_access_mask = .{ .shader_read = true }, .dst_access_mask = .{ .shader_write = true } },
        },
    });

    // Dispatch transmittance (256x64, groups 32x8)
    cmd.cmd_bind_compute_pipeline(self.transmittance_pipeline);
    cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.transmittance_descriptor_set } });
    cmd.cmd_dispatch(.{ .group_count_x = 32, .group_count_y = 8, .group_count_z = 1 });

    // Transmittance must be readable before multi-scatter
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true },
        .dst_stage = .{ .compute_shader = true },
        .image_barriers = &.{
            .{ .image = self.transmittance_image, .old_layout = .General, .new_layout = .ShaderReadOnlyOptimal,
               .src_access_mask = .{ .shader_write = true }, .dst_access_mask = .{ .shader_read = true } },
        },
    });

    // Dispatch multi-scatter (32x32, 64 threads per texel)
    cmd.cmd_bind_compute_pipeline(self.multi_scatter_pipeline);
    cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.multi_scatter_descriptor_set } });
    cmd.cmd_dispatch(.{ .group_count_x = 32, .group_count_y = 32, .group_count_z = 1 });

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true },
        .dst_stage = .{ .fragment_shader = true },
        .image_barriers = &.{
            .{ .image = self.multi_scatter_image, .old_layout = .General, .new_layout = .ShaderReadOnlyOptimal,
               .src_access_mask = .{ .shader_write = true }, .dst_access_mask = .{ .shader_read = true } },
        },
    });
}

pub fn update_luts(self: *Self, cmd: *gfx.CommandBuffer, camera: *const eng.camera.Camera, sun_direction: [3]f32) void {
    // Hot-reload sky-view pipeline
    if (self.sky_view_shader_watcher.was_modified_since_last_check()) blk: {
        const new_pipeline = self.create_sky_view_pipeline() catch |err| {
            std.log.err("atmosphere: sky_view shader reload failed: {}", .{err});
            break :blk;
        };
        self.sky_view_pipeline.deinit();
        self.sky_view_pipeline = new_pipeline;
        eng.get().gfx.flush();
    }

    const camera_altitude_km: f32 = camera.transform.position[1] / 1000.0;

    // Transition sky-view + aerial to General
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .fragment_shader = true },
        .dst_stage = .{ .compute_shader = true },
        .image_barriers = &.{
            .{ .image = self.sky_view_image, .old_layout = .ShaderReadOnlyOptimal, .new_layout = .General,
               .src_access_mask = .{ .shader_read = true }, .dst_access_mask = .{ .shader_write = true } },
            .{ .image = self.aerial_image, .old_layout = .ShaderReadOnlyOptimal, .new_layout = .General,
               .src_access_mask = .{ .shader_read = true }, .dst_access_mask = .{ .shader_write = true } },
        },
    });

    // Sky-view dispatch (25x13x1 covers 200x100 with early-out)
    {
        const push = SkyViewPushConstant {
            .sun_direction       = sun_direction,
            .camera_altitude_km  = camera_altitude_km,
        };
        cmd.cmd_bind_compute_pipeline(self.sky_view_pipeline);
        cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.sky_view_descriptor_set } });
        cmd.cmd_push_constants(.{
            .data = std.mem.asBytes(&push),
            .offset = 0,
            .shader_stages = .{ .Compute = true },
        });
        cmd.cmd_dispatch(.{ .group_count_x = 25, .group_count_y = 13, .group_count_z = 1 });
    }

    // Aerial perspective dispatch (4x4x32)
    {
        const inv_vp = zm.inverse(zm.mul(
            camera.transform.generate_view_matrix(),
            camera.generate_perspective_matrix(eng.get().gfx.swapchain_aspect()),
        ));
        const cam_pos_km = [3]f32{
            camera.transform.position[0] / 1000.0,
            camera.transform.position[1] / 1000.0,
            camera.transform.position[2] / 1000.0,
        };
        const push = AerialPushConstant {
            .inv_view_projection = inv_vp,
            .sun_direction       = sun_direction,
            .camera_position_km  = cam_pos_km,
        };
        cmd.cmd_bind_compute_pipeline(self.aerial_pipeline);
        cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.aerial_descriptor_set } });
        cmd.cmd_push_constants(.{
            .data = std.mem.asBytes(&push),
            .offset = 0,
            .shader_stages = .{ .Compute = true },
        });
        cmd.cmd_dispatch(.{ .group_count_x = 4, .group_count_y = 4, .group_count_z = 32 });
    }

    // Transition both back to shader-read
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true },
        .dst_stage = .{ .fragment_shader = true },
        .image_barriers = &.{
            .{ .image = self.sky_view_image, .old_layout = .General, .new_layout = .ShaderReadOnlyOptimal,
               .src_access_mask = .{ .shader_write = true }, .dst_access_mask = .{ .shader_read = true } },
            .{ .image = self.aerial_image, .old_layout = .General, .new_layout = .ShaderReadOnlyOptimal,
               .src_access_mask = .{ .shader_write = true }, .dst_access_mask = .{ .shader_read = true } },
        },
    });
}

pub fn render(self: *Self, cmd: *gfx.CommandBuffer, camera: *const eng.camera.Camera, sun_direction: [3]f32) void {
    const swapchain_size = gfx.GfxState.get().swapchain_size();
    const inv_vp = zm.inverse(zm.mul(
        camera.transform.generate_view_matrix(),
        camera.generate_perspective_matrix(gfx.GfxState.get().swapchain_aspect()),
    ));
    const cam_pos_km = [3]f32{
        camera.transform.position[0] / 1000.0,
        camera.transform.position[1] / 1000.0,
        camera.transform.position[2] / 1000.0,
    };
    const push = SkyAerialPushConstant{
        .inv_view_projection = inv_vp,
        .sun_direction       = sun_direction,
        .camera_position_km  = cam_pos_km,
        .aerial_km_per_slice = self.current_settings.aerial_perspective_km_per_slice,
    };

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .late_fragment_tests = true },
        .dst_stage = .{ .compute_shader = true },
        .image_barriers = &.{
            .{
                .image = eng.get().gfx.default.depth_image,
                .old_layout = .DepthStencilAttachmentOptimal,
                .new_layout = .ShaderReadOnlyOptimal,
                .src_access_mask = .{ .depth_stencil_attachment_write = true },
                .dst_access_mask = .{ .shader_read = true },
            },
            .{
                .image = eng.get().gfx.default.hdr_image,
                .old_layout = .ColorAttachmentOptimal,
                .new_layout = .General,
                .src_access_mask = .{ .color_attachment_write = true },
                .dst_access_mask = .{ .shader_read = true, .shader_write = true },
            },
        },
    });

    cmd.cmd_bind_compute_pipeline(self.sky_aerial_pipeline);
    cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.sky_aerial_descriptor_set } });
    cmd.cmd_push_constants(.{
        .data = std.mem.asBytes(&push),
        .offset = 0,
        .shader_stages = .{ .Compute = true },
    });
    cmd.cmd_dispatch(.{
        .group_count_x = (swapchain_size[0] + 7) / 8,
        .group_count_y = (swapchain_size[1] + 7) / 8,
        .group_count_z = 1,
    });

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true },
        .dst_stage = .{ .color_attachment_output = true, .early_fragment_tests = true },
        .image_barriers = &.{
            .{
                .image = eng.get().gfx.default.hdr_image,
                .old_layout = .General,
                .new_layout = .ColorAttachmentOptimal,
                .src_access_mask = .{ .shader_write = true },
                .dst_access_mask = .{ .color_attachment_write = true },
            },
            .{
                .image = eng.get().gfx.default.depth_image,
                .old_layout = .ShaderReadOnlyOptimal,
                .new_layout = .DepthStencilAttachmentOptimal,
                .src_access_mask = .{ .shader_read = true },
                .dst_access_mask = .{ .depth_stencil_attachment_write = true },
            },
        },
    });
}

// ---- Pipeline creation helpers ----

fn create_transmittance_pipeline(layout: gfx.DescriptorLayout.Ref) !gfx.ComputePipeline.Ref {
    const alloc = eng.get().general_allocator;
    const spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("atmosphere_transmittance.slang"),
        .shader_entry_points = &.{ "cs_main" },
    });
    defer alloc.free(spirv);
    const module = try gfx.ShaderModule.init(.{ .spirv_data = spirv });
    defer module.deinit();
    return gfx.ComputePipeline.init(.{
        .compute_shader = .{ .module = &module, .entry_point = "cs_main" },
        .descriptor_set_layouts = &.{ layout },
        .push_constants = &.{},
    });
}

fn create_multi_scatter_pipeline(layout: gfx.DescriptorLayout.Ref) !gfx.ComputePipeline.Ref {
    const alloc = eng.get().general_allocator;
    const spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("atmosphere_multi_scattering.slang"),
        .shader_entry_points = &.{ "cs_main" },
    });
    defer alloc.free(spirv);
    const module = try gfx.ShaderModule.init(.{ .spirv_data = spirv });
    defer module.deinit();
    return gfx.ComputePipeline.init(.{
        .compute_shader = .{ .module = &module, .entry_point = "cs_main" },
        .descriptor_set_layouts = &.{ layout },
        .push_constants = &.{},
    });
}

fn create_aerial_pipeline(layout: gfx.DescriptorLayout.Ref) !gfx.ComputePipeline.Ref {
    const alloc = eng.get().general_allocator;
    const spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("atmosphere_aerial_perspective.slang"),
        .shader_entry_points = &.{ "cs_main" },
        .preprocessor_macros = &.{},
    });
    defer alloc.free(spirv);
    const module = try gfx.ShaderModule.init(.{ .spirv_data = spirv });
    defer module.deinit();
    return gfx.ComputePipeline.init(.{
        .compute_shader = .{ .module = &module, .entry_point = "cs_main" },
        .descriptor_set_layouts = &.{ layout },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(AerialPushConstant),
            },
        },
    });
}

fn create_sky_aerial_pipeline(layout: gfx.DescriptorLayout.Ref) !gfx.ComputePipeline.Ref {
    const alloc = eng.get().general_allocator;
    const combined = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ AtmosphereCommonSrc, @embedFile("atmosphere_sky_aerial.slang") });
    defer alloc.free(combined);
    const spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = combined,
        .shader_entry_points = &.{ "cs_main" },
    });
    defer alloc.free(spirv);
    const module = try gfx.ShaderModule.init(.{ .spirv_data = spirv });
    defer module.deinit();
    return gfx.ComputePipeline.init(.{
        .compute_shader = .{ .module = &module, .entry_point = "cs_main" },
        .descriptor_set_layouts = &.{ layout },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(SkyAerialPushConstant),
            },
        },
    });
}

fn create_sky_view_pipeline(self: *Self) !gfx.ComputePipeline.Ref {
    const alloc = eng.get().general_allocator;

    const path = try eng.util.uri.resolve_file_uri(alloc, SkyViewShaderUri);
    defer alloc.free(path);

    const file = try std.fs.openFileAbsolute(path, .{ .mode = .read_only });
    defer file.close();

    const file_data = try alloc.alloc(u8, try file.getEndPos());
    defer alloc.free(file_data);
    _ = try file.readAll(file_data);

    // Prepend atmosphere_common.slang so its symbols are available to the shader
    const combined = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ AtmosphereCommonSrc, file_data });
    defer alloc.free(combined);

    const spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = combined,
        .shader_entry_points = &.{ "cs_main" },
    });
    defer alloc.free(spirv);

    const module = try gfx.ShaderModule.init(.{ .spirv_data = spirv });
    defer module.deinit();

    return gfx.ComputePipeline.init(.{
        .compute_shader = .{ .module = &module, .entry_point = "cs_main" },
        .descriptor_set_layouts = &.{ self.sky_view_descriptor_layout },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(SkyViewPushConstant),
            },
        },
    });
}

pub fn update_cubemap(self: *Self, cmd: *gfx.CommandBuffer, camera_altitude_km: f32, sun_direction: [3]f32) void {
    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .fragment_shader = true },
        .dst_stage = .{ .compute_shader = true },
        .image_barriers = &.{
            .{ .image = self.cubemap_image, .old_layout = .ShaderReadOnlyOptimal, .new_layout = .General,
               .src_access_mask = .{ .shader_read = true }, .dst_access_mask = .{ .shader_write = true } },
        },
    });

    const push = CubemapPushConstant {
        .sun_direction      = sun_direction,
        .camera_altitude_km = camera_altitude_km,
    };
    cmd.cmd_bind_compute_pipeline(self.cubemap_pipeline);
    cmd.cmd_bind_descriptor_sets(.{ .descriptor_sets = &.{ self.cubemap_descriptor_set } });
    cmd.cmd_push_constants(.{
        .data = std.mem.asBytes(&push),
        .offset = 0,
        .shader_stages = .{ .Compute = true },
    });
    cmd.cmd_dispatch(.{ .group_count_x = CUBEMAP_FACE_SIZE / 8, .group_count_y = CUBEMAP_FACE_SIZE / 8, .group_count_z = 6 });

    cmd.cmd_pipeline_barrier(.{
        .src_stage = .{ .compute_shader = true },
        .dst_stage = .{ .fragment_shader = true },
        .image_barriers = &.{
            .{ .image = self.cubemap_image, .old_layout = .General, .new_layout = .ShaderReadOnlyOptimal,
               .src_access_mask = .{ .shader_write = true }, .dst_access_mask = .{ .shader_read = true } },
        },
    });
}

fn create_cubemap_pipeline(layout: gfx.DescriptorLayout.Ref) !gfx.ComputePipeline.Ref {
    const alloc = eng.get().general_allocator;
    const combined = try std.fmt.allocPrint(alloc, "{s}\n{s}", .{ AtmosphereCommonSrc, CubemapShaderSrc });
    defer alloc.free(combined);
    const spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = combined,
        .shader_entry_points = &.{ "cs_main" },
    });
    defer alloc.free(spirv);
    const module = try gfx.ShaderModule.init(.{ .spirv_data = spirv });
    defer module.deinit();
    return gfx.ComputePipeline.init(.{
        .compute_shader = .{ .module = &module, .entry_point = "cs_main" },
        .descriptor_set_layouts = &.{ layout },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Compute = true },
                .offset = 0,
                .size = @sizeOf(CubemapPushConstant),
            },
        },
    });
}
