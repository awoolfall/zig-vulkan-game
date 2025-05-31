const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const ms = eng.mesh;
const gfx = eng.gfx;
const path = eng.path;
const cm = eng.camera;
const SelectionTextures = @import("selection_textures.zig");
const DepthTextures = @import("depth_textures.zig");

const CameraStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
    position: zm.F32x4,
    time: f32,
};

pub const RenderObject = struct {
    entity_id: ?u32,
    transform: zm.Mat,
    vertex_buffers: std.BoundedArray(gfx.VertexBufferInput, 8),
    vertex_count: usize,
    pos_offset: usize,
    index_buffer: ?IndexInfo,
    material: ms.MaterialTemplate,

    pub const IndexInfo = struct {
        buffer_info: gfx.VertexBufferInput,
        index_count: usize,
    };
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
        is_selected: bool,
        unlit: bool,
        pad: u30 = 0,
    },
    bone_start_idx: u32 = 0,
};

const bone_matrix_buffer_size: usize = 1024;

pub const LightType = enum (u32) {
    Directional = 0,
    Point = 1,
    Spot = 2,
};

pub const Light = extern struct {
    position: zm.F32x4 = zm.f32x4s(0.0),
    direction: zm.F32x4 = zm.f32x4(0.0, -1.0, 0.0, 0.0),
    colour: zm.F32x4 = zm.f32x4(1.0, 1.0, 1.0, 1.0),
    intensity: f32 = 0.0,
    umbra: f32 = std.math.degreesToRadians(20.0),
    delta_penumbra: f32 = std.math.degreesToRadians(0.5), // degrees smaller the penumbra is compared to the umbra
    light_type: LightType = .Directional,
};

const MAX_LIGHTS: usize = 4;
const LightsStruct = extern struct {
    lights: [MAX_LIGHTS]Light,
};

const ShaderSet = struct {
    vertex_shader: gfx.VertexShader,
    pixel_shader: gfx.PixelShader,

    pub fn deinit(self: *ShaderSet) void {
        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
    }
};

const Shaders = struct {
    static: ShaderSet,
    skeletal: ShaderSet,

    pub fn deinit(self: *Shaders) void {
        self.static.deinit();
        self.skeletal.deinit();
    }
};

shaders: Shaders,
shader_watcher: eng.assets.FileWatcher,

camera_data_buffer: gfx.Buffer,

instance_buffers: [3]gfx.Buffer,
instance_active_buffer: usize = 0,

lights_buffer: gfx.Buffer,
    
bone_matrix_buffer: gfx.Buffer,

render_objects: std.ArrayList(RenderObject),
skeletal_render_objects: std.ArrayList(AnimatedRenderObject),
render_bones: std.ArrayList(zm.Mat),
lights: std.ArrayList(Light),


pub fn deinit(self: *Self) void {
    self.shaders.deinit();
    self.shader_watcher.deinit();
    self.camera_data_buffer.deinit();
    for (&self.instance_buffers) |*ib| {
        ib.deinit();
    }
    self.lights_buffer.deinit();
    self.bone_matrix_buffer.deinit();
    self.render_objects.deinit();
    self.skeletal_render_objects.deinit();
    self.render_bones.deinit();
    self.lights.deinit();
}

pub fn init() !Self {
    const shaders = try init_shaders();

    const shader_path = path.Path{.ExeRelative = "../../src/shader.hlsl"};
    const full_shader_path = try shader_path.resolve_path(eng.get().frame_allocator);
    defer eng.get().frame_allocator.free(full_shader_path);

    std.log.info("shader path: '{s}'", .{full_shader_path});
    var shader_watcher = try eng.assets.FileWatcher.init(eng.get().general_allocator, full_shader_path, 500);
    errdefer shader_watcher.deinit();

    // Create camera constant buffer
    const camera_constant_buffer = try gfx.Buffer.init(
        @sizeOf(CameraStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        &eng.get().gfx
    );
    errdefer camera_constant_buffer.deinit();

    var instance_buffers: [3]gfx.Buffer = undefined;
    for (0..3) |i| {
        instance_buffers[i] = try gfx.Buffer.init(
            @sizeOf(InstanceStruct),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            &eng.get().gfx
        );
    }
    errdefer {
        for (&instance_buffers) |*ib| {
            ib.deinit();
        }
    }

    // Create bone matrix constant buffer
    const bone_matrix_buffer = try gfx.Buffer.init(
        @sizeOf(zm.Mat) * Self.bone_matrix_buffer_size,
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        &eng.get().gfx
    );
    errdefer bone_matrix_buffer.deinit();

    const lights_buffer = try gfx.Buffer.init(
        @sizeOf(LightsStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        &eng.get().gfx
    );
    errdefer lights_buffer.deinit();

    return Self {
        .shaders = shaders,
        .shader_watcher = shader_watcher,

        .camera_data_buffer = camera_constant_buffer,
        .instance_buffers = instance_buffers,
        .bone_matrix_buffer = bone_matrix_buffer,
        .lights_buffer = lights_buffer,

        .render_objects = try std.ArrayList(RenderObject).initCapacity(eng.get().general_allocator, 128),
        .skeletal_render_objects = try std.ArrayList(AnimatedRenderObject).initCapacity(eng.get().general_allocator, 32),
        .render_bones = try std.ArrayList(zm.Mat).initCapacity(eng.get().general_allocator, Self.bone_matrix_buffer_size),
        .lights = try std.ArrayList(Light).initCapacity(eng.get().general_allocator, 4),
    };
}

fn init_shaders() !Shaders {
    const shader_path = path.Path{.ExeRelative = "../../src/shader.hlsl"};

    var shaders = Shaders{
        .static = undefined,
        .skeletal = undefined,
    };

    shaders.skeletal = ShaderSet{
        .vertex_shader = undefined,
        .pixel_shader = undefined,
    };

    shaders.skeletal.vertex_shader = try gfx.VertexShader.init_file(
        eng.get().general_allocator, 
        shader_path, 
        "vs_main",
        ([_]gfx.VertexInputLayoutEntry {
            .{ .name = "POS",                   .format = .F32x3,   .per = .Vertex, .slot = 0, },
            .{ .name = "NORMAL",                .format = .F32x3,   .per = .Vertex, .slot = 1, },
            .{ .name = "TANGENT",               .format = .F32x3,   .per = .Vertex, .slot = 2, },
            .{ .name = "BITANGENT",             .format = .F32x3,   .per = .Vertex, .slot = 3, },
            .{ .name = "TEXCOORD",  .index = 0, .format = .F32x2,   .per = .Vertex, .slot = 4, },
            .{ .name = "BONE_IDS",              .format = .I32x4,   .per = .Vertex, .slot = 5, },
            .{ .name = "BONE_WEIGHTS",          .format = .F32x4,   .per = .Vertex, .slot = 6, },
        })[0..],
        .{
            .defines = &.{
                .{ "SKELETAL_RENDERING", "1" },
            },
        },
        &eng.get().gfx
    );
    errdefer shaders.skeletal.vertex_shader.deinit();

    shaders.skeletal.pixel_shader = try gfx.PixelShader.init_file(
        eng.get().general_allocator, 
        shader_path,
        "ps_main",
        .{
            .defines = &.{
                .{ "SKELETAL_RENDERING", "1" },
            },
        },
        &eng.get().gfx
    );
    errdefer shaders.skeletal.pixel_shader.deinit();

    shaders.static = ShaderSet{
        .vertex_shader = undefined,
        .pixel_shader = undefined,
    };

    shaders.static.vertex_shader = try gfx.VertexShader.init_file(
        eng.get().general_allocator, 
        shader_path, 
        "vs_main",
        ([_]gfx.VertexInputLayoutEntry {
            .{ .name = "POS",                   .format = .F32x3,   .per = .Vertex, .slot = 0, },
            .{ .name = "NORMAL",                .format = .F32x3,   .per = .Vertex, .slot = 1, },
            .{ .name = "TANGENT",               .format = .F32x3,   .per = .Vertex, .slot = 2, },
            .{ .name = "BITANGENT",             .format = .F32x3,   .per = .Vertex, .slot = 3, },
            .{ .name = "TEXCOORD",  .index = 0, .format = .F32x2,   .per = .Vertex, .slot = 4, },
        })[0..],
        .{},
        &eng.get().gfx
    );
    errdefer shaders.static.vertex_shader.deinit();

    shaders.static.pixel_shader = try gfx.PixelShader.init_file(
        eng.get().general_allocator, 
        shader_path,
        "ps_main",
        .{},
        &eng.get().gfx
    );
    errdefer shaders.static.pixel_shader.deinit();

    return shaders;
}

pub fn push(self: *Self, ro: RenderObject) !void {
    self.render_objects.append(ro) catch unreachable;
}

pub fn push_animated(self: *Self, sro: AnimatedRenderObject) !void {
    self.skeletal_render_objects.append(sro) catch unreachable;
}

pub fn push_bones(self: *Self, bones: []const zm.Mat) !struct { start_idx: usize, end_idx: usize, } {
    const start_idx = self.render_bones.items.len;
    self.render_bones.appendSlice(bones) catch unreachable;
    const end_idx = self.render_bones.items.len;
    return .{ .start_idx = start_idx, .end_idx = end_idx, };
}

pub fn push_light(self: *Self, light: Light) !void {
    self.lights.append(light) catch unreachable;
}

pub fn clear(self: *Self) void {
    self.render_objects.clearRetainingCapacity();
    self.skeletal_render_objects.clearRetainingCapacity();
    self.render_bones.clearRetainingCapacity();
    self.lights.clearRetainingCapacity();
}

pub fn update_camera_data_buffer(self: *Self, camera: *const cm.Camera) void {
    const mapped_buffer = self.camera_data_buffer.map(CameraStruct, &eng.get().gfx) catch unreachable;
    defer mapped_buffer.unmap();

    mapped_buffer.data().* = .{
        .projection = camera.generate_perspective_matrix(eng.get().gfx.swapchain_aspect()),
        .view = camera.transform.generate_view_matrix(),
        .position = camera.transform.position,
        .time = @floatCast(eng.get().time.time_since_start_of_app()),
    };
}

pub fn render(
    self: *Self, 
    rtv: *const gfx.RenderTargetView, 
    selection_rtv: *const gfx.RenderTargetView,
    depth_view: *const gfx.DepthStencilView,
    data: struct {
        selected_entity_idx: ?usize,
    },
) void {
    if (self.shader_watcher.was_modified_since_last_check()) {
        blk: {
            const new_shaders = init_shaders() catch |err| {
                std.log.err("Failed to reload shaders: {}", .{err});
                break :blk;
            };
            self.shaders.deinit();
            self.shaders = new_shaders;
        }
    }

    eng.get().gfx.cmd_set_render_target(&.{rtv, selection_rtv}, depth_view);

    const viewport = gfx.Viewport {
        .width = @floatFromInt(eng.get().gfx.swapchain_size.width),
        .height = @floatFromInt(eng.get().gfx.swapchain_size.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
        .top_left_x = 0.0,
        .top_left_y = 0.0,
    };
    eng.get().gfx.cmd_set_viewport(viewport);

    eng.get().gfx.cmd_set_blend_state(null);

    eng.get().gfx.cmd_set_constant_buffers(.Vertex, 0, &[_]*const gfx.Buffer{
        &self.camera_data_buffer,
        &self.instance_buffers[0],
        &self.instance_buffers[0],
        &self.bone_matrix_buffer, // TODO
    });
    eng.get().gfx.cmd_set_constant_buffers(.Pixel, 0, &[_]*const gfx.Buffer{
        &self.camera_data_buffer,
        &self.instance_buffers[0], // slot 1 will be overwritten by later
        &self.lights_buffer,
        &self.instance_buffers[0],
    });

    eng.get().gfx.cmd_set_topology(.TriangleList);

    // render boneless objects
    eng.get().gfx.cmd_set_vertex_shader(&self.shaders.static.vertex_shader);
    eng.get().gfx.cmd_set_pixel_shader(&self.shaders.static.pixel_shader);

    var top_bone_idx: usize = 0;
    var start_bone_idx: usize = 0;
    for (self.render_objects.items) |*ro| {
        self.instance_active_buffer = (self.instance_active_buffer + 1) % 3;
        const instance_buffer = &self.instance_buffers[self.instance_active_buffer];

        // Setup model buffer from transform
        {
            const mapped_buffer = instance_buffer.map(InstanceStruct, &eng.get().gfx) catch unreachable;
            defer mapped_buffer.unmap();

            const entity_id = if (ro.entity_id) |e| e else 0;
            mapped_buffer.data().* = InstanceStruct {
                .model_matrix = ro.transform,
                .entity_id = entity_id,
                .flags = .{
                    .is_selected = if (data.selected_entity_idx) |s| (entity_id == s) else false,
                    .unlit = ro.material.unlit,
                },
                .bone_start_idx = 0,
            };
        }

        // Render the render object
        eng.get().gfx.cmd_set_constant_buffers(.Vertex, 1, &.{instance_buffer});
        eng.get().gfx.cmd_set_constant_buffers(.Pixel, 1, &.{instance_buffer});

        eng.get().gfx.cmd_set_vertex_buffers(0, ro.vertex_buffers.slice());

        if (ro.material.double_sided) {
            eng.get().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = true, });
        } else {
            eng.get().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = false, });
        }

        var diffuse = &eng.get().gfx.default.diffuse;
        var diffuse_sampler = &eng.get().gfx.default.sampler;
        if (ro.material.diffuse_map) |*d| {
            diffuse = &d.map;
            if (d.sampler) |*s| { diffuse_sampler = s; }
        }
        eng.get().gfx.cmd_set_shader_resources(.Pixel, 0, &.{diffuse});
        eng.get().gfx.cmd_set_samplers(.Pixel, 0, &.{diffuse_sampler});

        self.update_lights_buffer(&ro.transform);

        if (ro.index_buffer) |ib| {
            eng.get().gfx.cmd_set_index_buffer(ib.buffer_info.buffer, .U32, 0);
            eng.get().gfx.cmd_draw_indexed(@truncate(ib.index_count), ib.buffer_info.offset, @intCast(ro.pos_offset));
        } else {
            eng.get().gfx.cmd_draw(@truncate(ro.vertex_count), 0);
        }
    }

    // render skeletal objects
    eng.get().gfx.cmd_set_vertex_shader(&self.shaders.skeletal.vertex_shader);
    eng.get().gfx.cmd_set_pixel_shader(&self.shaders.skeletal.pixel_shader);

    top_bone_idx = 0;
    start_bone_idx = 0;
    for (self.skeletal_render_objects.items) |*sro| {
        // if bones are not within the uploaded bone set, then move the window
        if (sro.bone_info.bone_offset + sro.bone_info.bone_count > top_bone_idx) {
            @branchHint(.unlikely);

            top_bone_idx = sro.bone_info.bone_offset;
            start_bone_idx = top_bone_idx;

            // Update bone matrix buffer
            const mapped_buffer = self.bone_matrix_buffer.map([Self.bone_matrix_buffer_size]zm.Mat, &eng.get().gfx) catch unreachable;
            defer mapped_buffer.unmap();

            const copy_amount = @min(self.render_bones.items.len - start_bone_idx, Self.bone_matrix_buffer_size);
            @memcpy(mapped_buffer.data().*[0..copy_amount], self.render_bones.items[start_bone_idx..][0..copy_amount]);

            top_bone_idx += copy_amount;
        }

        var ro = &sro.standard;

        self.instance_active_buffer = (self.instance_active_buffer + 1) % 3;
        const instance_buffer = &self.instance_buffers[self.instance_active_buffer];

        // Setup model buffer from transform
        {
            const mapped_buffer = instance_buffer.map(InstanceStruct, &eng.get().gfx) catch unreachable;
            defer mapped_buffer.unmap();

            const entity_id = if (ro.entity_id) |e| e else 0;
            mapped_buffer.data().* = InstanceStruct {
                .model_matrix = ro.transform,
                .entity_id = entity_id,
                .flags = .{
                    .is_selected = if (data.selected_entity_idx) |s| (entity_id == s) else false,
                    .unlit = ro.material.unlit,
                },
                .bone_start_idx = @truncate(sro.bone_info.bone_offset - start_bone_idx),
            };
        }

        // Render the render object
        eng.get().gfx.cmd_set_constant_buffers(.Vertex, 1, &.{instance_buffer});
        eng.get().gfx.cmd_set_constant_buffers(.Pixel, 1, &.{instance_buffer});

        eng.get().gfx.cmd_set_vertex_buffers(0, ro.vertex_buffers.slice());

        if (ro.material.double_sided) {
            eng.get().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = true, });
        } else {
            eng.get().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = false, });
        }

        var diffuse = &eng.get().gfx.default.diffuse;
        var diffuse_sampler = &eng.get().gfx.default.sampler;
        if (ro.material.diffuse_map) |*d| {
            diffuse = &d.map;
            if (d.sampler) |*s| { diffuse_sampler = s; }
        }
        eng.get().gfx.cmd_set_shader_resources(.Pixel, 0, &.{diffuse});
        eng.get().gfx.cmd_set_samplers(.Pixel, 0, &.{diffuse_sampler});

        self.update_lights_buffer(&ro.transform);

        if (ro.index_buffer) |ib| {
            eng.get().gfx.cmd_set_index_buffer(ib.buffer_info.buffer, .U32, 0);
            eng.get().gfx.cmd_draw_indexed(@truncate(ib.index_count), ib.buffer_info.offset, @intCast(ro.pos_offset));
        } else {
            eng.get().gfx.cmd_draw(@truncate(ro.vertex_count), 0);
        }
    }
}

fn lights_sort_func(pos: zm.F32x4, a: Light, b: Light) bool {
    const a_dist = zm.length3(a.position - pos)[0] - a.intensity;
    const b_dist = zm.length3(b.position - pos)[0] - b.intensity;
    return a_dist < b_dist;
}

fn update_lights_buffer(self: *Self, transform: *const zm.Mat) void {
    const entity_position = transform[3];
    // TODO: probably should use a quadtree or something here
    std.mem.sort(Light, self.lights.items, entity_position, lights_sort_func);

    { // Update lights buffer
        const mapped_buffer = self.lights_buffer.map(LightsStruct, &eng.get().gfx) catch unreachable;
        defer mapped_buffer.unmap();

        var i: usize = 0;
        while (i < self.lights.items.len and i < MAX_LIGHTS) : (i += 1) {
            mapped_buffer.data().lights[i] = self.lights.items[i];
        }
        while (i < MAX_LIGHTS) : (i += 1) {
            mapped_buffer.data().lights[i] = .{};
        }
    }
}

