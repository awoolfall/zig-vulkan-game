const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const ms = eng.mesh;
const gfx = eng.gfx;
const path = eng.path;
const cm = eng.camera;
const sr = eng.serialize;
const SelectionTextures = @import("selection_textures.zig");

const CameraStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
    position: zm.F32x4,
    time: f32,
};

pub const RenderObject = struct {
    entity_id: ?u32,
    transform: zm.Mat,
    vertex_buffers: [4]gfx.VertexBufferInput,
    vertex_buffers_count: u8 = 0,
    vertex_count: usize,
    pos_offset: usize,
    index_buffer: ?IndexInfo,
    material: ms.MaterialTemplate,

    pub const IndexInfo = struct {
        buffer_info: gfx.VertexBufferInput,
        index_count: usize,
    };

    pub fn vertex_buffers_slice(self: *const RenderObject) []const gfx.VertexBufferInput {
        return self.vertex_buffers[0..self.vertex_buffers_count];
    }
};

pub const AnimatedRenderObject = struct {
    standard: RenderObject,
    bone_info: BoneInfo,

    pub const BoneInfo = struct {
        bone_count: usize,
        bone_offset: usize,
    };
};

const InstanceStruct = extern struct {
    model_matrix: zm.Mat,
    entity_id: u32,
    flags: packed struct(u32) {
        unlit: bool,
        pad: u31 = 0,
    },
    bone_start_idx: u32 = 0,
};

pub const LightType = enum (u32) {
    None = 0,
    Sun = 1,
    Directional = 2,
    Point = 3,
    Spot = 4,
};

pub const Light = extern struct {
    position: zm.F32x4 = zm.f32x4s(0.0),
    direction: zm.F32x4 = zm.f32x4(0.0, -1.0, 0.0, 0.0),
    colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
    intensity: f32 = 0.0,
    umbra: f32 = std.math.degreesToRadians(20.0),
    delta_penumbra: f32 = std.math.degreesToRadians(0.5), // degrees smaller the penumbra is compared to the umbra
    light_type: LightType = .None,

    fn serialize(self: *const Light, alloc: std.mem.Allocator) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("position", try sr.serialize_value(zm.F32x4, alloc, self.position));
        try object.put("direction", try sr.serialize_value(zm.F32x4, alloc, self.direction));
        try object.put("colour", try sr.serialize_value(zm.F32x4, alloc, self.colour));
        try object.put("intensity", try sr.serialize_value(f32, alloc, self.intensity));
        try object.put("umbra", try sr.serialize_value(f32, alloc, std.math.radiansToDegrees(self.umbra)));
        try object.put("delta_penumbra", try sr.serialize_value(f32, alloc, std.math.radiansToDegrees(self.delta_penumbra)));
        try object.put("light_type", try sr.serialize_value(LightType, alloc, self.light_type));

        return std.json.Value { .object = object };
    }

    fn deserialize(value: std.json.Value) !Light {
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType };

        var light = Light{};

        if (object.get("position")) |v| blk: { light.position = sr.deserialize_value(zm.F32x4, v) catch break :blk; }
        if (object.get("direction")) |v| blk: { light.direction = sr.deserialize_value(zm.F32x4, v) catch break :blk; }
        if (object.get("colour")) |v| blk: { light.colour = sr.deserialize_value(zm.F32x4, v) catch break :blk; }
        if (object.get("intensity")) |v| blk: { light.intensity = sr.deserialize_value(f32, v) catch break :blk; }
        if (object.get("umbra")) |v| blk: { light.umbra = std.math.degreesToRadians(sr.deserialize_value(f32, v) catch break :blk); }
        if (object.get("delta_penumbra")) |v| blk: { light.delta_penumbra = std.math.degreesToRadians(sr.deserialize_value(f32, v) catch break :blk); }
        if (object.get("light_type")) |v| blk: { light.light_type = sr.deserialize_value(LightType, v) catch break :blk; }

        return light;
    }
};

pub const MAX_LIGHTS: usize = 4;
pub const LightsStruct = extern struct {
    lights: [MAX_LIGHTS]Light,
};

const PushConstants = extern struct {
    instance_index: u32,
    lights_index: u32,
    bone_start_index: u32,
    __pad: u32 = 0,
};

const BufferData = struct {
    buffer: gfx.Buffer.Ref, // TODO frames in flight
    descriptor_set: gfx.DescriptorSet.Ref,

    pub fn deinit(self: *const BufferData) void {
        self.descriptor_set.deinit();
        self.buffer.deinit();
    }
};

const StandardRenderPipeline = struct {
    solid: gfx.GraphicsPipeline.Ref,
    transparent: gfx.GraphicsPipeline.Ref,

    pub fn deinit(self: *const StandardRenderPipeline) void {
        self.solid.deinit();
        self.transparent.deinit();
    }
};

const GraphicsPipelines = struct {
    static: StandardRenderPipeline,
    skeletal: StandardRenderPipeline,

    pub fn deinit(self: *const GraphicsPipelines) void {
        self.static.deinit();
        self.skeletal.deinit();
    }
};

const MAX_OBJECTS_PER_INSTANCE_BUFFER = 64;
const MAX_OBJECTS_PER_LIGHTS_BUFFER = 64;
const MAX_BONES_PER_BUFFER = 1024;

shader_watcher: eng.assets.FileWatcher,

camera_data_buffer: BufferData,
instance_buffers: std.ArrayList(BufferData),
lights_buffers: std.ArrayList(BufferData),
bone_buffers: std.ArrayList(BufferData),

camera_data_layout: gfx.DescriptorLayout.Ref,
camera_data_descriptor_pool: gfx.DescriptorPool.Ref,

instance_data_layout: gfx.DescriptorLayout.Ref,
instance_data_descriptor_pool: gfx.DescriptorPool.Ref,

lights_data_layout: gfx.DescriptorLayout.Ref,
lights_data_descriptor_pool: gfx.DescriptorPool.Ref,

textures_data_layout: gfx.DescriptorLayout.Ref,
textures_data_descriptor_pool: gfx.DescriptorPool.Ref,
default_textures_set: gfx.DescriptorSet.Ref,
texture_data_sets: std.ArrayList(?gfx.DescriptorSet.Ref),

bones_data_layout: gfx.DescriptorLayout.Ref,
bones_data_descriptor_pool: gfx.DescriptorPool.Ref,

graphics_pipelines: GraphicsPipelines,

render_pass: gfx.RenderPass.Ref,
framebuffer: gfx.FrameBuffer.Ref,

render_objects: std.ArrayList(RenderObject),
skeletal_render_objects: std.ArrayList(AnimatedRenderObject),
render_bones: std.ArrayList(zm.Mat),
lights: std.ArrayList(Light),

selection_textures: SelectionTextures.SelectionTextures(u32),


pub fn deinit(self: *Self) void {
    const general_alloc = eng.get().general_allocator;

    self.selection_textures.deinit();

    self.shader_watcher.deinit();

    self.camera_data_buffer.deinit();
    for (self.instance_buffers.items) |b| { b.deinit(); }
    self.instance_buffers.deinit(general_alloc);
    for (self.lights_buffers.items) |b| { b.deinit(); }
    self.lights_buffers.deinit(general_alloc);
    for (self.bone_buffers.items) |b| { b.deinit(); }
    self.bone_buffers.deinit(general_alloc);

    self.camera_data_descriptor_pool.deinit();
    self.camera_data_layout.deinit();

    self.instance_data_descriptor_pool.deinit();
    self.instance_data_layout.deinit();

    self.lights_data_descriptor_pool.deinit();
    self.lights_data_layout.deinit();

    for (self.texture_data_sets.items) |m_s| {
        if (m_s) |s| {
            s.deinit();
        }
    }
    self.texture_data_sets.deinit(general_alloc);

    self.default_textures_set.deinit();
    self.textures_data_descriptor_pool.deinit();
    self.textures_data_layout.deinit();

    self.bones_data_descriptor_pool.deinit();
    self.bones_data_layout.deinit();

    self.graphics_pipelines.deinit();
    self.framebuffer.deinit();
    self.render_pass.deinit();

    self.render_objects.deinit(general_alloc);
    self.skeletal_render_objects.deinit(general_alloc);
    self.render_bones.deinit(general_alloc);
    self.lights.deinit(general_alloc);
}

pub fn init() !Self {
    var selection_textures = try SelectionTextures.SelectionTextures(u32).init();
    errdefer selection_textures.deinit();

    const shader_path = try path.Path.init(eng.get().general_allocator, .{.ExeRelative = "../../src/shader.slang"});
    defer shader_path.deinit();

    const full_shader_path = try shader_path.resolve_path(eng.get().frame_allocator);
    defer eng.get().frame_allocator.free(full_shader_path);

    std.log.info("shader path: '{s}'", .{full_shader_path});
    var shader_watcher = try eng.assets.FileWatcher.init(eng.get().general_allocator, full_shader_path, 500);
    errdefer shader_watcher.deinit();
    
    const camera_data_descriptor_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .binding = 0,
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .binding_type = .UniformBuffer,
            },
        },
    });
    errdefer camera_data_descriptor_layout.deinit();

    const camera_data_descriptor_pool = try gfx.DescriptorPool.init(.{
        .max_sets = 1,
        .strategy = .{ .Layout = camera_data_descriptor_layout, },
    });
    errdefer camera_data_descriptor_pool.deinit();

    const camera_data_descriptor_set = try (camera_data_descriptor_pool.get() catch unreachable).allocate_set(
        .{ .layout = camera_data_descriptor_layout, },
    );
    errdefer camera_data_descriptor_set.deinit();

    const camera_data_buffer = blk: {
        const buffer = try gfx.Buffer.init(
            @sizeOf(CameraStruct),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
        );
        errdefer buffer.deinit();

        try (camera_data_descriptor_set.get() catch unreachable).update(.{
            .writes = &.{
                gfx.DescriptorSetUpdateWriteInfo {
                    .binding = 0,
                    .data = .{ .UniformBuffer = .{
                        .buffer = buffer,
                    } },
                },
            },
        });

        break :blk BufferData {
            .buffer = buffer,
            .descriptor_set = camera_data_descriptor_set,
        };
    };

    const instance_data_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .binding = 0,
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .binding_type = .UniformBuffer,
            },
        },
    });
    errdefer instance_data_layout.deinit();

    const instance_data_descriptor_pool = try gfx.DescriptorPool.init(.{
        .max_sets = 512,
        .strategy = .{ .Layout = instance_data_layout, },
    });
    errdefer instance_data_descriptor_pool.deinit();

    const lights_data_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .binding = 0,
                .shader_stages = .{ .Pixel = true, },
                .binding_type = .UniformBuffer,
            },
        },
    });
    errdefer lights_data_layout.deinit();

    const lights_data_descriptor_pool = try gfx.DescriptorPool.init(.{
        .max_sets = 512,
        .strategy = .{ .Layout = lights_data_layout, },
    });
    errdefer lights_data_descriptor_pool.deinit();

    const textures_data_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            // diffuse
            gfx.DescriptorBindingInfo {
                .binding = 0,
                .shader_stages = .{ .Pixel = true, },
                .binding_type = .ImageView,
            },
            gfx.DescriptorBindingInfo {
                .binding = 1,
                .shader_stages = .{ .Pixel = true, },
                .binding_type = .Sampler,
            },
            // TODO pbr
            // additional
        },
    });
    errdefer textures_data_layout.deinit();

    const textures_descriptor_pool = try gfx.DescriptorPool.init(.{
        .max_sets = 512,
        .strategy = .{ .Layout = textures_data_layout, },
    });
    errdefer textures_descriptor_pool.deinit();

    const default_textures_set = try (textures_descriptor_pool.get() catch unreachable).allocate_set(.{
        .layout = textures_data_layout,
    });
    errdefer default_textures_set.deinit();

    try (default_textures_set.get() catch unreachable).update(.{
        .writes = &.{
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .ImageView = gfx.GfxState.get().default.diffuse_view, },
            },
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 1,
                .data = .{ .Sampler = gfx.GfxState.get().default.sampler, },
            },
        },
    });

    const bones_data_layout = try gfx.DescriptorLayout.init(.{
        .bindings = &.{
            gfx.DescriptorBindingInfo {
                .binding = 0,
                .shader_stages = .{ .Vertex = true, },
                .binding_type = .UniformBuffer,
            },
        },
    });
    errdefer bones_data_layout.deinit();

    const bones_data_descriptor_pool = try gfx.DescriptorPool.init(.{
        .max_sets = 512,
        .strategy = .{ .Layout = bones_data_layout, },
    });
    errdefer bones_data_descriptor_pool.deinit();

    const attachments = &[_]gfx.AttachmentInfo {
        gfx.AttachmentInfo {
            .name = "colour_opaque",
            .format = gfx.GfxState.hdr_format,
            .load_op = .Clear,
            .clear_value = gfx.ClearValue{ .f32x4 = zm.srgbToRgb(zm.f32x4(133.0/255.0, 193.0/255.0, 233.0/255.0, 1.0)) },
            .initial_layout = .Undefined,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .None,
        },
        gfx.AttachmentInfo {
            .name = "colour_blend",
            .format = gfx.GfxState.hdr_format,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .Simple,
        },
        gfx.AttachmentInfo {
            .name = "entity_clear",
            .format = gfx.ImageFormat.R32_Uint,
            .load_op = .Clear,
            .clear_value = gfx.ClearValue { .u32x4 = [1]u32 {std.math.maxInt(u32)} ** 4 },
            .initial_layout = .Undefined,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .None,
        },
        gfx.AttachmentInfo {
            .name = "entity",
            .format = gfx.ImageFormat.R32_Uint,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .None,
        },
        gfx.AttachmentInfo {
            .name = "depth",
            .format = gfx.GfxState.depth_format,
            .load_op = .Clear,
            .stencil_load_op = .Clear,
            .initial_layout = .Undefined,
            .final_layout = .DepthStencilAttachmentOptimal,
            .clear_value = gfx.ClearValue { .depth_stencil = .{ .depth = 0.0, .stencil = 0 } },
        },
    };

    const render_pass = try gfx.RenderPass.init(.{
        .attachments = attachments,
        .subpasses = &[_]gfx.SubpassInfo {
            // opaque
            .{
                .attachments = &.{ 
                    "colour_opaque",
                    "entity_clear",
                },
                .depth_attachment = "depth",
            },
            // transparent
            .{
                .attachments = &.{
                    "colour_blend",
                    "entity",
                },
                .depth_attachment = "depth",
            },
        },
        .dependencies = &.{
            gfx.SubpassDependencyInfo {
                .src_subpass = null,
                .dst_subpass = 0,
                .src_stage_mask = .{ .color_attachment_output = true, },
                .src_access_mask = .{},
                .dst_stage_mask = .{ .color_attachment_output = true, },
                .dst_access_mask = .{ .color_attachment_write = true, },
            },
            gfx.SubpassDependencyInfo {
                .src_subpass = 0,
                .dst_subpass = 1,
                .src_stage_mask = .{ .color_attachment_output = true, },
                .src_access_mask = .{},
                .dst_stage_mask = .{ .color_attachment_output = true, },
                .dst_access_mask = .{ .color_attachment_write = true, },
            },
        },
    });
    errdefer render_pass.deinit();

    const framebuffer = try gfx.FrameBuffer.init(.{
        .render_pass = render_pass,
        .attachments = &.{
            .SwapchainHDR,
            .SwapchainHDR,
            .{ .View = selection_textures.view },
            .{ .View = selection_textures.view },
            .SwapchainDepth,
        },
    });
    errdefer framebuffer.deinit();

    const graphics_pipelines = try create_graphics_pipelines(.{
        .render_pass = render_pass,
        
        .camera_data_descriptor_layout = camera_data_descriptor_layout,
        .instance_data_layout = instance_data_layout,
        .lights_data_layout = lights_data_layout,
        .textures_data_layout = textures_data_layout,
        .bones_data_layout = bones_data_layout,
    });
    errdefer graphics_pipelines.deinit();


    return Self {
        .shader_watcher = shader_watcher,

        .camera_data_layout = camera_data_descriptor_layout,
        .camera_data_descriptor_pool = camera_data_descriptor_pool,

        .instance_data_layout = instance_data_layout,
        .instance_data_descriptor_pool = instance_data_descriptor_pool,

        .lights_data_layout = lights_data_layout,
        .lights_data_descriptor_pool = lights_data_descriptor_pool,

        .textures_data_layout = textures_data_layout,
        .textures_data_descriptor_pool = textures_descriptor_pool,
        .default_textures_set = default_textures_set,
        .texture_data_sets = std.ArrayList(?gfx.DescriptorSet.Ref).empty,

        .bones_data_layout = bones_data_layout,
        .bones_data_descriptor_pool = bones_data_descriptor_pool,

        .camera_data_buffer = camera_data_buffer,
        .instance_buffers = std.ArrayList(BufferData).empty,
        .lights_buffers = std.ArrayList(BufferData).empty,
        .bone_buffers = std.ArrayList(BufferData).empty,

        .render_pass = render_pass,
        .framebuffer = framebuffer,
        .graphics_pipelines = graphics_pipelines,

        .render_objects = std.ArrayList(RenderObject).empty,
        .skeletal_render_objects = std.ArrayList(AnimatedRenderObject).empty,
        .render_bones = std.ArrayList(zm.Mat).empty,
        .lights = std.ArrayList(Light).empty,

        .selection_textures = selection_textures,
    };
}

const CreateGraphicsPipelinesInfo = struct {
    render_pass: gfx.RenderPass.Ref,

    camera_data_descriptor_layout: gfx.DescriptorLayout.Ref,
    instance_data_layout: gfx.DescriptorLayout.Ref,
    lights_data_layout: gfx.DescriptorLayout.Ref,
    textures_data_layout: gfx.DescriptorLayout.Ref,
    bones_data_layout: gfx.DescriptorLayout.Ref,
};

fn create_graphics_pipelines(info: CreateGraphicsPipelinesInfo) !GraphicsPipelines {
    const alloc = eng.get().general_allocator;

    const skeletal_vertex_input = try gfx.VertexInput.init(.{
        .bindings = &.{
            .{ .binding = 0, .stride = 88, .input_rate = .Vertex, },
        },
        .attributes = &.{
            .{ .name = "POS",           .location = 0, .binding = 0, .offset = 0,  .format = .F32x3, },
            .{ .name = "NORMAL",        .location = 1, .binding = 0, .offset = 12, .format = .F32x3, },
            .{ .name = "TANGENT",       .location = 2, .binding = 0, .offset = 24, .format = .F32x3, },
            //.{ .name = "BITANGENT",     .location = 3, .binding = 0, .offset = 36, .format = .F32x3, },
            .{ .name = "TEXCOORD0",     .location = 4, .binding = 0, .offset = 48, .format = .F32x2, },
            .{ .name = "BONE_IDS",      .location = 5, .binding = 0, .offset = 56, .format = .I32x4, },
            .{ .name = "BONE_WEIGHTS",  .location = 6, .binding = 0, .offset = 72, .format = .F32x4, },
        },
    });
    defer skeletal_vertex_input.deinit();

    const static_vertex_input = try gfx.VertexInput.init(.{
        .bindings = &.{
            .{ .binding = 0, .stride = 88, .input_rate = .Vertex, },
        },
        .attributes = &.{
            .{ .name = "POS",           .location = 0, .binding = 0, .offset = 0,  .format = .F32x3, },
            .{ .name = "NORMAL",        .location = 1, .binding = 0, .offset = 12, .format = .F32x3, },
            .{ .name = "TANGENT",       .location = 2, .binding = 0, .offset = 24, .format = .F32x3, },
            //.{ .name = "BITANGENT",     .location = 3, .binding = 0, .offset = 36, .format = .F32x3, },
            .{ .name = "TEXCOORD0",     .location = 4, .binding = 0, .offset = 48, .format = .F32x2, },
            // .{ .name = "BONE_IDS",      .location = 5, .binding = 0, .offset = 56, .format = .I32x4, },
            // .{ .name = "BONE_WEIGHTS",  .location = 6, .binding = 0, .offset = 72, .format = .F32x4, },
        },
    });
    defer static_vertex_input.deinit();
    
    const shader_path = try path.Path.init(alloc, .{.ExeRelative = "../../src/shader.slang"});
    defer shader_path.deinit();

    const resolved_shader_path = try shader_path.resolve_path(alloc);
    defer alloc.free(resolved_shader_path);

    const shader_file = try std.fs.openFileAbsolute(resolved_shader_path, .{ .mode = .read_only });
    defer shader_file.close();

    const slang_code = try alloc.alloc(u8, try shader_file.getEndPos());
    defer alloc.free(slang_code);

    _ = try shader_file.readAll(slang_code);

    const skeletal_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = slang_code,
        .preprocessor_macros = &.{
            .{ "SKELETAL_RENDERING", "1" },
            .{ "RENDER_ENTITY_ID_BUFFER", "1" },
            .{ "BONE_BUFFER_SIZE", std.fmt.comptimePrint("{}", .{Self.MAX_BONES_PER_BUFFER}) },
        },
        .shader_entry_points = &.{
            "vs_main",
            "ps_main",
        }
    });
    defer alloc.free(skeletal_spirv);
    
    const static_spirv = try gfx.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = slang_code,
        .preprocessor_macros = &.{
            .{ "RENDER_ENTITY_ID_BUFFER", "1" },
        },
        .shader_entry_points = &.{
            "vs_main",
            "ps_main",
        }
    });
    defer alloc.free(static_spirv);

    const skeletal_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = skeletal_spirv,
    });
    defer skeletal_shader_module.deinit();

    const static_shader_module = try gfx.ShaderModule.init(.{
        .spirv_data = static_spirv,
    });
    defer static_shader_module.deinit();
    

    // static pipelines
    const solid_pipeline_info = gfx.GraphicsPipelineInfo {
        .vertex_shader = .{
            .module = &static_shader_module,
            .entry_point = "vs_main",
        },
        .vertex_input = &static_vertex_input,
        .pixel_shader = .{
            .module = &static_shader_module,
            .entry_point = "ps_main",
        },

        .cull_mode = .CullBack,
        .descriptor_set_layouts = &.{
            info.camera_data_descriptor_layout,
            info.instance_data_layout,
            info.lights_data_layout,
            info.textures_data_layout,
        },
        .push_constants = &.{
            gfx.PushConstantLayoutInfo {
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .size = @sizeOf(PushConstants),
                .offset = 0,
            },
        },
        .depth_test = .{ .write = true, },
        .render_pass = info.render_pass,
        .subpass_index = 0,
    };

    var transparent_pipeline_info = solid_pipeline_info;
    transparent_pipeline_info.depth_test = .{ .write = false, };
    transparent_pipeline_info.subpass_index = 1;

    var static_solid_pipeline_info = solid_pipeline_info;
    static_solid_pipeline_info.vertex_input = &static_vertex_input;
    static_solid_pipeline_info.vertex_shader = .{
        .module = &static_shader_module,
        .entry_point = "vs_main",
    };
    static_solid_pipeline_info.pixel_shader = .{
        .module = &static_shader_module,
        .entry_point = "ps_main",
    };

    var static_transparent_pipeline_info = transparent_pipeline_info;
    static_transparent_pipeline_info.vertex_input = &static_vertex_input;
    static_transparent_pipeline_info.vertex_shader = .{
        .module = &static_shader_module,
        .entry_point = "vs_main",
    };
    static_transparent_pipeline_info.pixel_shader = .{
        .module = &static_shader_module,
        .entry_point = "ps_main",
    };

    const static_solid_pipeline = try gfx.GraphicsPipeline.init(static_solid_pipeline_info);
    errdefer static_solid_pipeline.deinit();

    const static_transparent_pipeline = try gfx.GraphicsPipeline.init(static_transparent_pipeline_info);
    errdefer static_transparent_pipeline.deinit();


    // skeletal pipelines
    const skeletal_descriptor_layouts: []const gfx.DescriptorLayout.Ref = &.{
        info.camera_data_descriptor_layout,
        info.instance_data_layout,
        info.lights_data_layout,
        info.textures_data_layout,
        info.bones_data_layout,
    };

    var skeletal_solid_pipeline_info = solid_pipeline_info;
    skeletal_solid_pipeline_info.descriptor_set_layouts = skeletal_descriptor_layouts;
    skeletal_solid_pipeline_info.vertex_input = &skeletal_vertex_input;
    skeletal_solid_pipeline_info.vertex_shader = .{
        .module = &skeletal_shader_module,
        .entry_point = "vs_main",
    };
    skeletal_solid_pipeline_info.pixel_shader = .{
        .module = &skeletal_shader_module,
        .entry_point = "ps_main",
    };
    skeletal_solid_pipeline_info.descriptor_set_layouts = skeletal_descriptor_layouts;

    var skeletal_transparent_pipeline_info = transparent_pipeline_info;
    skeletal_transparent_pipeline_info.descriptor_set_layouts = skeletal_descriptor_layouts;
    skeletal_transparent_pipeline_info.vertex_input = &skeletal_vertex_input;
    skeletal_transparent_pipeline_info.vertex_shader = .{
        .module = &skeletal_shader_module,
        .entry_point = "vs_main",
    };
    skeletal_transparent_pipeline_info.pixel_shader = .{
        .module = &skeletal_shader_module,
        .entry_point = "ps_main",
    };

    const skeletal_solid_pipeline = try gfx.GraphicsPipeline.init(skeletal_solid_pipeline_info);
    errdefer skeletal_solid_pipeline.deinit();

    const skeletal_transparent_pipeline = try gfx.GraphicsPipeline.init(skeletal_transparent_pipeline_info);
    errdefer skeletal_transparent_pipeline.deinit();


    return GraphicsPipelines {
        .skeletal = .{
            .solid = skeletal_solid_pipeline,
            .transparent = skeletal_transparent_pipeline,
        },
        .static = .{
            .solid = static_solid_pipeline,
            .transparent = static_transparent_pipeline,
        }
    };
}

pub fn push(self: *Self, ro: RenderObject) !void {
    self.render_objects.append(eng.get().general_allocator, ro) catch unreachable;
}

pub fn push_animated(self: *Self, sro: AnimatedRenderObject) !void {
    self.skeletal_render_objects.append(eng.get().general_allocator, sro) catch unreachable;
}

pub fn push_bones(self: *Self, bones: []const zm.Mat) !struct { start_idx: usize, end_idx: usize, } {
    const start_idx = self.render_bones.items.len;
    self.render_bones.appendSlice(eng.get().general_allocator, bones) catch unreachable;
    const end_idx = self.render_bones.items.len;
    return .{ .start_idx = start_idx, .end_idx = end_idx, };
}

pub fn push_light(self: *Self, light: Light) !void {
    self.lights.append(eng.get().general_allocator, light) catch unreachable;
}

pub fn clear(self: *Self) void {
    self.render_objects.clearRetainingCapacity();
    self.skeletal_render_objects.clearRetainingCapacity();
    self.render_bones.clearRetainingCapacity();
    self.lights.clearRetainingCapacity();
}

pub fn update_camera_data_buffer(self: *Self, camera: *const cm.Camera) void {
    const buffer = self.camera_data_buffer.buffer.get() catch |err| {
        std.log.warn("Unable to get camera data buffer: {}", .{err});
        return;
    };
    const mapped_buffer = buffer.map(.{ .write = .EveryFrame, }) catch unreachable;
    defer mapped_buffer.unmap();

    mapped_buffer.data(CameraStruct).* = .{
        .projection = camera.generate_perspective_matrix(eng.get().gfx.swapchain_aspect()),
        .view = camera.transform.generate_view_matrix(),
        .position = camera.transform.position,
        .time = @floatCast(eng.get().time.time_since_start_of_app()),
    };
}

fn append_new_instance_buffer(
    self: *Self,
) !void {
    const buffer = try gfx.Buffer.init(
        @sizeOf(InstanceStruct) * Self.MAX_OBJECTS_PER_INSTANCE_BUFFER,
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer buffer.deinit();

    const descriptor_set = try (self.instance_data_descriptor_pool.get() catch unreachable).allocate_set(.{
        .layout = self.instance_data_layout,
    });
    errdefer descriptor_set.deinit();

    try (descriptor_set.get() catch unreachable).update(.{
        .writes = &.{
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .UniformBuffer = .{
                    .buffer = buffer,
                } },
            },
            },
        });

    const buffer_data = BufferData {
        .buffer = buffer,
        .descriptor_set = descriptor_set,
    };

    try self.instance_buffers.append(eng.get().general_allocator, buffer_data);
}

fn append_new_lights_buffer(
    self: *Self,
) !void {
    const buffer = try gfx.Buffer.init(
        @sizeOf(LightsStruct) * Self.MAX_OBJECTS_PER_LIGHTS_BUFFER,
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer buffer.deinit();

    const descriptor_set = try (self.lights_data_descriptor_pool.get() catch unreachable).allocate_set(.{
        .layout = self.lights_data_layout,
    });
    errdefer descriptor_set.deinit();

    try (descriptor_set.get() catch unreachable).update(.{
        .writes = &.{
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .UniformBuffer = .{
                    .buffer = buffer,
                } },
            },
            },
        });

    const buffer_data = BufferData {
        .buffer = buffer,
        .descriptor_set = descriptor_set,
    };

    try self.lights_buffers.append(eng.get().general_allocator, buffer_data);
}

fn append_new_bones_buffer(
    self: *Self,
) !void {
    const buffer = try gfx.Buffer.init(
        @sizeOf(zm.Mat) * Self.MAX_BONES_PER_BUFFER,
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer buffer.deinit();

    const descriptor_set = try (self.bones_data_descriptor_pool.get() catch unreachable).allocate_set(.{
        .layout = self.bones_data_layout,
    });
    errdefer descriptor_set.deinit();

    try (descriptor_set.get() catch unreachable).update(.{
        .writes = &.{
            gfx.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .UniformBuffer = .{
                    .buffer = buffer,
                } },
            },
            },
        });

    const buffer_data = BufferData {
        .buffer = buffer,
        .descriptor_set = descriptor_set,
    };

    try self.bone_buffers.append(eng.get().general_allocator, buffer_data);
}

pub fn render_cmd(
    self: *Self,
    data: struct {
        camera: *const cm.Camera,
    },
    cmd: *gfx.CommandBuffer,
) !void {
    if (self.shader_watcher.was_modified_since_last_check()) blk: {
        std.log.info("Recreating graphics pipelines for standard renderer", .{});
        
        const new_graphics_pipelines = create_graphics_pipelines(.{
            .render_pass = self.render_pass,
            
            .camera_data_descriptor_layout = self.camera_data_layout,
            .instance_data_layout = self.instance_data_layout,
            .lights_data_layout = self.lights_data_layout,
            .textures_data_layout = self.textures_data_layout,
            .bones_data_layout = self.bones_data_layout,
        }) catch |err| {
            std.log.err("Unable to recreate graphics pipelines: {}", .{err});
            break :blk;
        };

        self.graphics_pipelines.deinit();
        self.graphics_pipelines = new_graphics_pipelines;
    }

    cmd.cmd_begin_render_pass(.{
        .framebuffer = self.framebuffer,
        .render_pass = self.render_pass,
        .render_area = .full_screen_pixels(),
    });
    defer cmd.cmd_end_render_pass();

    cmd.cmd_set_viewports(.{
        .viewports = &.{ .full_screen_viewport(), },
    });
    cmd.cmd_set_scissors(.{
        .scissors = &.{ .full_screen_pixels(), },
    });

    cmd.cmd_bind_graphics_pipeline(self.graphics_pipelines.static.solid);

    self.update_camera_data_buffer(data.camera);
    cmd.cmd_bind_descriptor_sets(.{
        .first_binding = 0,
        .descriptor_sets = &.{
            self.camera_data_buffer.descriptor_set,
        }
    });

    var current_instance_buffer_index: isize = -1;
    var mapped_instance_data: gfx.Buffer.MappedBuffer = undefined;
    defer if (current_instance_buffer_index >= 0) { mapped_instance_data.unmap(); };

    var current_lights_buffer_index: isize = -1;
    var mapped_lights_data: gfx.Buffer.MappedBuffer = undefined;
    defer if (current_lights_buffer_index >= 0) { mapped_lights_data.unmap(); };

    var current_bones_buffer_index: isize = -1;
    var mapped_bones_data: gfx.Buffer.MappedBuffer = undefined;
    defer if (current_bones_buffer_index >= 0) { mapped_bones_data.unmap(); };

    var idx: usize = 0;

    for (self.render_objects.items) |ro| {
        if (idx >= Self.MAX_OBJECTS_PER_INSTANCE_BUFFER * (current_instance_buffer_index + 1)) {
            current_instance_buffer_index += 1;

            if (self.instance_buffers.items.len == current_instance_buffer_index) {
                try self.append_new_instance_buffer();
            }

            if (current_instance_buffer_index != 0) {
                mapped_instance_data.unmap();
            }
            const new_instance_buffer = self.instance_buffers.items[@intCast(current_instance_buffer_index)].buffer.get() catch unreachable;
            mapped_instance_data = try new_instance_buffer.map(.{ .write = .EveryFrame, });

            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 1,
                .descriptor_sets = &.{
                    self.instance_buffers.items[@intCast(current_instance_buffer_index)].descriptor_set
                },
            });
        }

        if (idx >= Self.MAX_OBJECTS_PER_LIGHTS_BUFFER * (current_lights_buffer_index + 1)) {
            current_lights_buffer_index += 1;

            if (self.lights_buffers.items.len == current_lights_buffer_index) {
                try self.append_new_lights_buffer();
            }

            if (current_lights_buffer_index != 0) {
                mapped_lights_data.unmap();
            }
            const new_lights_buffer = self.lights_buffers.items[@intCast(current_lights_buffer_index)].buffer.get() catch unreachable;
            mapped_lights_data = try new_lights_buffer.map(.{ .write = .EveryFrame, });

            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 2,
                .descriptor_sets = &.{
                    self.lights_buffers.items[@intCast(current_lights_buffer_index)].descriptor_set
                },
            });
        }

        // Set instance data
        const entity_id = if (ro.entity_id) |e| e else 0;
        mapped_instance_data.data_array(InstanceStruct, Self.MAX_OBJECTS_PER_INSTANCE_BUFFER)[idx % Self.MAX_OBJECTS_PER_INSTANCE_BUFFER] = InstanceStruct {
            .model_matrix = ro.transform,
            .entity_id = entity_id,
            .flags = .{
                .unlit = ro.material.unlit,
            },
            .bone_start_idx = 0,
        };

        // Set lights data
        {
            const entity_position = ro.transform[3];
            self.sort_lights(entity_position);

            const mapped_lights = &mapped_lights_data.data_array(LightsStruct, Self.MAX_OBJECTS_PER_LIGHTS_BUFFER)[idx % Self.MAX_OBJECTS_PER_LIGHTS_BUFFER];

            var i: usize = 0;
            while (i < self.lights.items.len and i < MAX_LIGHTS) : (i += 1) {
                mapped_lights.lights[i] = self.lights.items[i];
            }
            while (i < MAX_LIGHTS) : (i += 1) {
                mapped_lights.lights[i] = .{};
            }
        }

        // textures
        if (idx == self.texture_data_sets.items.len) {
            try self.texture_data_sets.append(eng.get().general_allocator, null);
        }

        if (ro.material.diffuse_map) |diffuse_map| {
            const texture_data_set = &self.texture_data_sets.items[idx];

            if (texture_data_set.* == null) {
                const textures_data_pool = self.textures_data_descriptor_pool.get() catch unreachable;

                texture_data_set.* = try textures_data_pool.allocate_set(.{ .layout = self.textures_data_layout, });
            }

            const set = texture_data_set.*.?.get() catch unreachable;

            try set.update(.{
                .writes = &.{
                    gfx.DescriptorSetUpdateWriteInfo {
                        .binding = 0,
                        .data = .{ .ImageView = diffuse_map.map, },
                    },
                    gfx.DescriptorSetUpdateWriteInfo {
                        .binding = 1,
                        .data = .{ .Sampler = diffuse_map.sampler orelse gfx.GfxState.get().default.sampler, },
                    },
                },
            });

            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 3,
                .descriptor_sets = &.{
                    texture_data_set.*.?
                }
            });
        } else {
            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 3,
                .descriptor_sets = &.{
                    self.default_textures_set
                }
            });
        }

        cmd.cmd_bind_vertex_buffers(.{
            .first_binding = 0,
            .buffers = ro.vertex_buffers_slice(),
        });

        const push_constants = PushConstants {
            .instance_index = @intCast(idx % Self.MAX_OBJECTS_PER_INSTANCE_BUFFER),
            .lights_index = 0,
            .bone_start_index = 0,
        };

        cmd.cmd_push_constants(.{
            .offset = 0,
            .data = std.mem.asBytes(&push_constants),
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
        });

        if (ro.index_buffer) |ib| {
            cmd.cmd_bind_index_buffer(.{
                .buffer = ib.buffer_info.buffer,
                .index_format = .U32,
                .offset = ib.buffer_info.offset,
            });

            cmd.cmd_draw_indexed(.{
                .index_count = @intCast(ib.index_count),
                .vertex_offset = @intCast(ro.pos_offset),
            });
        } else {
            cmd.cmd_draw(.{
                .vertex_count = @intCast(ro.vertex_count),
            });
        }

        idx += 1;
    }

    // render animated objects

    cmd.cmd_bind_graphics_pipeline(self.graphics_pipelines.skeletal.solid);

    self.update_camera_data_buffer(data.camera);
    cmd.cmd_bind_descriptor_sets(.{
        .first_binding = 0,
        .descriptor_sets = &.{
            self.camera_data_buffer.descriptor_set,
        }
    });
    
    var start_bone_idx: isize = -Self.MAX_BONES_PER_BUFFER;

    for (self.skeletal_render_objects.items) |sro| {
        const ro = sro.standard;

        if (idx >= Self.MAX_OBJECTS_PER_INSTANCE_BUFFER * (current_instance_buffer_index + 1)) {
            current_instance_buffer_index += 1;

            if (self.instance_buffers.items.len == current_instance_buffer_index) {
                try self.append_new_instance_buffer();
            }

            if (current_instance_buffer_index != 0) {
                mapped_instance_data.unmap();
            }
            const new_instance_buffer = self.instance_buffers.items[@intCast(current_instance_buffer_index)].buffer.get() catch unreachable;
            mapped_instance_data = try new_instance_buffer.map(.{ .write = .EveryFrame, });

            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 1,
                .descriptor_sets = &.{
                    self.instance_buffers.items[@intCast(current_instance_buffer_index)].descriptor_set
                },
            });
        }

        // Set instance data
        const entity_id = if (ro.entity_id) |e| e else 0;
        mapped_instance_data.data_array(InstanceStruct, Self.MAX_OBJECTS_PER_INSTANCE_BUFFER)[idx % Self.MAX_OBJECTS_PER_INSTANCE_BUFFER] = InstanceStruct {
            .model_matrix = ro.transform,
            .entity_id = entity_id,
            .flags = .{
                .unlit = ro.material.unlit,
            },
            .bone_start_idx = 0,
        };

        if (idx >= Self.MAX_OBJECTS_PER_LIGHTS_BUFFER * (current_lights_buffer_index + 1)) {
            current_lights_buffer_index += 1;

            if (self.lights_buffers.items.len == current_lights_buffer_index) {
                try self.append_new_lights_buffer();
            }

            if (current_lights_buffer_index != 0) {
                mapped_lights_data.unmap();
            }
            const new_lights_buffer = self.lights_buffers.items[@intCast(current_lights_buffer_index)].buffer.get() catch unreachable;
            mapped_lights_data = try new_lights_buffer.map(.{ .write = .EveryFrame, });

            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 2,
                .descriptor_sets = &.{
                    self.lights_buffers.items[@intCast(current_lights_buffer_index)].descriptor_set
                },
            });
        }

        // Set lights data
        {
            const entity_position = ro.transform[3];
            self.sort_lights(entity_position);

            const mapped_lights = &mapped_lights_data.data_array(LightsStruct, Self.MAX_OBJECTS_PER_LIGHTS_BUFFER)[idx % Self.MAX_OBJECTS_PER_LIGHTS_BUFFER];

            var i: usize = 0;
            while (i < self.lights.items.len and i < MAX_LIGHTS) : (i += 1) {
                mapped_lights.lights[i] = self.lights.items[i];
            }
            while (i < MAX_LIGHTS) : (i += 1) {
                mapped_lights.lights[i] = .{};
            }
        }

        // textures
        if (idx == self.texture_data_sets.items.len) {
            try self.texture_data_sets.append(eng.get().general_allocator, null);
        }

        if (ro.material.diffuse_map) |diffuse_map| {
            const texture_data_set = &self.texture_data_sets.items[idx];

            if (texture_data_set.* == null) {
                const textures_data_pool = self.textures_data_descriptor_pool.get() catch unreachable;

                texture_data_set.* = try textures_data_pool.allocate_set(.{ .layout = self.textures_data_layout, });
            }

            const set = texture_data_set.*.?.get() catch unreachable;

            try set.update(.{
                .writes = &.{
                    gfx.DescriptorSetUpdateWriteInfo {
                        .binding = 0,
                        .data = .{ .ImageView = diffuse_map.map, },
                    },
                    gfx.DescriptorSetUpdateWriteInfo {
                        .binding = 1,
                        .data = .{ .Sampler = diffuse_map.sampler orelse gfx.GfxState.get().default.sampler, },
                    },
                },
            });

            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 3,
                .descriptor_sets = &.{
                    texture_data_set.*.?
                }
            });
        } else {
            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 3,
                .descriptor_sets = &.{
                    self.default_textures_set
                }
            });
        }
        
        // bones
        // if bones are not within the uploaded bone set, then move the window
        if (sro.bone_info.bone_offset + sro.bone_info.bone_count >= start_bone_idx + Self.MAX_BONES_PER_BUFFER) {
            current_bones_buffer_index += 1;

            if (current_bones_buffer_index == self.bone_buffers.items.len) {
                try self.append_new_bones_buffer();
            }

            start_bone_idx = @intCast(sro.bone_info.bone_offset);

            if (current_bones_buffer_index != 0) {
                mapped_bones_data.unmap();
            }
            const new_bones_buffer = self.bone_buffers.items[@intCast(current_bones_buffer_index)].buffer.get() catch unreachable;
            mapped_bones_data = try new_bones_buffer.map(.{ .write = .EveryFrame, });

            const copy_amount: usize = @min(self.render_bones.items.len - @as(usize, @intCast(start_bone_idx)), Self.MAX_BONES_PER_BUFFER);
            @memcpy(
                mapped_bones_data.data_array(zm.Mat, Self.MAX_BONES_PER_BUFFER)[0..copy_amount], 
                self.render_bones.items[@intCast(start_bone_idx)..(@as(usize, @intCast(start_bone_idx)) + copy_amount)]
            );

            cmd.cmd_bind_descriptor_sets(.{
                .first_binding = 4,
                .descriptor_sets = &.{
                    self.bone_buffers.items[@intCast(current_bones_buffer_index)].descriptor_set,
                }
            });
        }

        cmd.cmd_bind_vertex_buffers(.{
            .first_binding = 0,
            .buffers = ro.vertex_buffers_slice(),
        });

        const push_constants = PushConstants {
            .instance_index = @intCast(idx % Self.MAX_OBJECTS_PER_INSTANCE_BUFFER),
            .lights_index = 0,
            .bone_start_index = @intCast(@max(0, start_bone_idx)),
        };

        cmd.cmd_push_constants(.{
            .offset = 0,
            .data = std.mem.asBytes(&push_constants),
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
        });

        if (ro.index_buffer) |ib| {
            cmd.cmd_bind_index_buffer(.{
                .buffer = ib.buffer_info.buffer,
                .index_format = .U32,
                .offset = ib.buffer_info.offset,
            });

            cmd.cmd_draw_indexed(.{
                .index_count = @intCast(ib.index_count),
                .vertex_offset = @intCast(ro.pos_offset),
            });
        } else {
            cmd.cmd_draw(.{
                .vertex_count = @intCast(ro.vertex_count),
            });
        }

        idx += 1;
    }

    cmd.cmd_next_subpass(.{});
}

fn lights_sort_func(pos: zm.F32x4, a: Light, b: Light) bool {
    if (a.light_type == .None) { return false; }
    if (b.light_type == .None) { return true; }
    if (a.light_type == .Sun) { return true; }
    if (b.light_type == .Sun) { return false; }
    
    const a_dist = zm.length3(a.position - pos)[0] - a.intensity;
    const b_dist = zm.length3(b.position - pos)[0] - b.intensity;
    return a_dist < b_dist;
}

pub fn sort_lights(self: *Self, position: zm.F32x4) void {
    std.mem.sort(Light, self.lights.items, position, lights_sort_func);
}

fn update_lights_buffer(self: *Self, transform: *const zm.Mat) void {
    const entity_position = transform[3];
    // TODO: probably should use a quadtree or something here
    self.sort_lights(entity_position);

    { // Update lights buffer
        const mapped_buffer = self.lights_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        var i: usize = 0;
        while (i < self.lights.items.len and i < MAX_LIGHTS) : (i += 1) {
            mapped_buffer.data(LightsStruct).lights[i] = self.lights.items[i];
        }
        while (i < MAX_LIGHTS) : (i += 1) {
            mapped_buffer.data(LightsStruct).lights[i] = .{};
        }
    }
}
