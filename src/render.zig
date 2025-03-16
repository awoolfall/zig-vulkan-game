const Self = @This();

const std = @import("std");
const en = @import("engine");
const engine = en.engine;
const zm = en.zmath;
const ms = en.mesh;
const gfx = en.gfx;
const path = en.path;
const cm = en.camera;
const SelectionTextures = @import("selection_textures.zig");
const DepthTextures = @import("depth_textures.zig");

const CameraStruct = extern struct {
    projection: [4]zm.F32x4,
    view: [4]zm.F32x4,
};

pub const RenderObject = struct {
    entity_id: ?u32,
    transform: zm.Mat,
    vertex_buffers: std.BoundedArray(gfx.VertexBufferInput, 6),
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
    time: f32,
    entity_id: u32,
    flags: packed struct(u32) {
        is_selected: bool,
        pad: u31 = 0,
    },
};

const InstanceIdx = extern struct {
    instance_idx: u32,
    bone_start_idx: u32 = 0,
    pad: [2]u32 = .{ 0, 0 },
};

const model_buffer_size: usize = 128;
const bone_matrix_buffer_size: usize = 1024;


vertex_shader: gfx.VertexShader,
pixel_shader: gfx.PixelShader,

camera_data_buffer: gfx.Buffer,
model_buffer: gfx.Buffer,

instance_index_buffers: [3]gfx.Buffer,
instance_index_active_buffer: usize = 0,
    
bone_matrix_buffer: gfx.Buffer,

render_objects: std.ArrayList(RenderObject),
skeletal_render_objects: std.ArrayList(AnimatedRenderObject),
render_bones: std.ArrayList(zm.Mat),


pub fn deinit(self: *Self) void {
    self.vertex_shader.deinit();
    self.pixel_shader.deinit();
    self.camera_data_buffer.deinit();
    self.model_buffer.deinit();
    for (&self.instance_index_buffers) |*ib| {
        ib.deinit();
    }
    self.bone_matrix_buffer.deinit();
    self.render_objects.deinit();
    self.skeletal_render_objects.deinit();
    self.render_bones.deinit();
}

pub fn init() !Self {
    const vertex_shader = try gfx.VertexShader.init_file(
        engine().general_allocator.allocator(), 
        path.Path{.ExeRelative = "../../src/shader.hlsl"}, 
        "vs_main",
        ([_]gfx.VertexInputLayoutEntry {
            .{ .name = "POS",                   .format = .F32x3,   .per = .Vertex, .slot = 0, },
            .{ .name = "NORMAL",                .format = .F32x3,   .per = .Vertex, .slot = 1, },
            .{ .name = "TEXCOORD",  .index = 0, .format = .F32x2,   .per = .Vertex, .slot = 2, },
            .{ .name = "TEXCOORD",  .index = 1, .format = .I32x4,   .per = .Vertex, .slot = 3, },
            .{ .name = "TEXCOORD",  .index = 2, .format = .F32x4,   .per = .Vertex, .slot = 4, },
        })[0..],
        .{},
        &engine().gfx
    );
    errdefer vertex_shader.deinit();

    const pixel_shader = try gfx.PixelShader.init_file(
        engine().general_allocator.allocator(), 
        path.Path{.ExeRelative = "../../src/shader.hlsl"}, 
        "ps_main",
        .{},
        &engine().gfx
    );
    errdefer pixel_shader.deinit();

    // Create camera constant buffer
    const camera_constant_buffer = try gfx.Buffer.init(
        @sizeOf(CameraStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        &engine().gfx
    );
    errdefer camera_constant_buffer.deinit();

    const model_buffer = try gfx.Buffer.init(
        @sizeOf(InstanceStruct) * Self.model_buffer_size,
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        &engine().gfx
    );
    errdefer model_buffer.deinit();

    var instance_index_buffers: [3]gfx.Buffer = undefined;
    for (0..3) |i| {
        instance_index_buffers[i] = try gfx.Buffer.init(
            @sizeOf(InstanceIdx),
            .{ .ConstantBuffer = true, },
            .{ .CpuWrite = true, },
            &engine().gfx
        );
    }
    errdefer {
        for (&instance_index_buffers) |*ib| {
            ib.deinit();
        }
    }

    // Create bone matrix constant buffer
    const bone_matrix_buffer = try gfx.Buffer.init(
        @sizeOf(zm.Mat) * Self.bone_matrix_buffer_size,
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        &engine().gfx
    );
    errdefer bone_matrix_buffer.deinit();

    return Self {
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,

        .camera_data_buffer = camera_constant_buffer,
        .model_buffer = model_buffer,
        .instance_index_buffers = instance_index_buffers,
        .bone_matrix_buffer = bone_matrix_buffer,

        .render_objects = try std.ArrayList(RenderObject).initCapacity(engine().general_allocator.allocator(), 128),
        .skeletal_render_objects = try std.ArrayList(AnimatedRenderObject).initCapacity(engine().general_allocator.allocator(), 32),
        .render_bones = try std.ArrayList(zm.Mat).initCapacity(engine().general_allocator.allocator(), Self.bone_matrix_buffer_size),
    };
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

pub fn clear(self: *Self) void {
    self.render_objects.clearRetainingCapacity();
    self.skeletal_render_objects.clearRetainingCapacity();
    self.render_bones.clearRetainingCapacity();
}

pub fn update_camera_data_buffer(self: *Self, camera: *const cm.Camera) void {
    const mapped_buffer = self.camera_data_buffer.map(CameraStruct, &engine().gfx) catch unreachable;
    defer mapped_buffer.unmap();

    mapped_buffer.data().* = .{
        .projection = camera.generate_perspective_matrix(engine().gfx.swapchain_aspect()),
        .view = camera.transform.generate_view_matrix(),
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
    engine().gfx.cmd_set_render_target(&.{rtv, selection_rtv}, depth_view);

    const viewport = gfx.Viewport {
        .width = @floatFromInt(engine().gfx.swapchain_size.width),
        .height = @floatFromInt(engine().gfx.swapchain_size.height),
        .min_depth = 0.0,
        .max_depth = 1.0,
        .top_left_x = 0.0,
        .top_left_y = 0.0,
    };
    engine().gfx.cmd_set_viewport(viewport);

    engine().gfx.cmd_set_vertex_shader(&self.vertex_shader);
    engine().gfx.cmd_set_pixel_shader(&self.pixel_shader);

    engine().gfx.cmd_set_blend_state(null);

    engine().gfx.cmd_set_constant_buffers(.Vertex, 0, &[_]*const gfx.Buffer{
        &self.camera_data_buffer,
        &self.model_buffer,
        &self.bone_matrix_buffer, // TODO
    });
    engine().gfx.cmd_set_constant_buffers(.Pixel, 0, &[_]*const gfx.Buffer{
        &self.camera_data_buffer,
        &self.model_buffer, // slot 1 will be overwritten by later
    });

    engine().gfx.cmd_set_topology(.TriangleList);

    // render boneless objects
    { // Update bone matrix buffer
        const mapped_buffer = self.bone_matrix_buffer.map([Self.bone_matrix_buffer_size]zm.Mat, &engine().gfx) catch unreachable;
        defer mapped_buffer.unmap();

        @memset(mapped_buffer.data().*[0..], zm.identity());
    }

    var top_bone_idx: usize = 0;
    var start_bone_idx: usize = 0;
    var top_model_idx: usize = 0;
    for (self.render_objects.items, 0..) |*ro, obj_idx| {
        if (obj_idx >= top_model_idx) {
            @branchHint(.unlikely);

            // Setup model buffer from transform
            const time_since_start_of_app: f32 = @floatCast(engine().time.time_since_start_of_app());
            {
                const mapped_buffer = self.model_buffer.map(InstanceStruct, &engine().gfx) catch unreachable;
                defer mapped_buffer.unmap();

                for (0..Self.model_buffer_size) |i| {
                    if (top_model_idx + i >= self.render_objects.items.len) break;
                    const iro = &self.render_objects.items[top_model_idx + i];

                    const entity_id = if (iro.entity_id) |e| e else 0;
                    mapped_buffer.data_array(Self.model_buffer_size)[i] = InstanceStruct {
                        .model_matrix = iro.transform,
                        .time = time_since_start_of_app,
                        .entity_id = entity_id,
                        .flags = .{
                            .is_selected = if (data.selected_entity_idx) |s| (entity_id == s) else false,
                        },
                    };
                }
            }

            top_model_idx += Self.model_buffer_size;
        }

        // Render the render object
        const instance_idx_buffer = &self.instance_index_buffers[self.instance_index_active_buffer];
        self.instance_index_active_buffer = (self.instance_index_active_buffer + 1) % 3;
        {
            const mapped_buffer = instance_idx_buffer.map(InstanceIdx, &engine().gfx) catch unreachable;
            defer mapped_buffer.unmap();
            mapped_buffer.data().instance_idx = @truncate(obj_idx + Self.model_buffer_size - top_model_idx);
            mapped_buffer.data().bone_start_idx = 0;
        }
        engine().gfx.cmd_set_constant_buffers(.Vertex, 3, &.{instance_idx_buffer});
        engine().gfx.cmd_set_constant_buffers(.Pixel, 3, &.{instance_idx_buffer});

        engine().gfx.cmd_set_vertex_buffers(0, ro.vertex_buffers.slice());

        if (ro.material.double_sided) {
            engine().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = true, });
        } else {
            engine().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = false, });
        }

        var diffuse = &engine().gfx.default.diffuse;
        var diffuse_sampler = &engine().gfx.default.sampler;
        if (ro.material.diffuse_map) |*d| {
            diffuse = &d.map;
            if (d.sampler) |*s| { diffuse_sampler = s; }
        }
        engine().gfx.cmd_set_shader_resources(.Pixel, 0, &.{diffuse});
        engine().gfx.cmd_set_samplers(.Pixel, 0, &.{diffuse_sampler});

        if (ro.index_buffer) |ib| {
            engine().gfx.cmd_set_index_buffer(ib.buffer_info.buffer, .U32, 0);
            engine().gfx.cmd_draw_indexed(@truncate(ib.index_count), ib.buffer_info.offset, @intCast(ro.pos_offset));
        } else {
            engine().gfx.cmd_draw(@truncate(ro.vertex_count), 0);
        }
    }

    // render skeletal objects
    top_bone_idx = 0;
    start_bone_idx = 0;
    top_model_idx = 0;
    for (self.skeletal_render_objects.items, 0..) |*sro, obj_idx| {
        // if bones are not within the uploaded bone set, then move the window
        if (sro.bone_info.bone_offset + sro.bone_info.bone_count > top_bone_idx) {
            @branchHint(.unlikely);

            top_bone_idx = sro.bone_info.bone_offset;
            start_bone_idx = top_bone_idx;

            // Update bone matrix buffer
            const mapped_buffer = self.bone_matrix_buffer.map([Self.bone_matrix_buffer_size]zm.Mat, &engine().gfx) catch unreachable;
            defer mapped_buffer.unmap();

            const copy_amount = @min(self.render_bones.items.len - start_bone_idx, Self.bone_matrix_buffer_size);
            @memcpy(mapped_buffer.data().*[0..copy_amount], self.render_bones.items[start_bone_idx..][0..copy_amount]);

            top_bone_idx += copy_amount;
        }

        var ro = &sro.standard;

        if (obj_idx >= top_model_idx) {
            @branchHint(.unlikely);

            // Setup model buffer from transform
            const time_since_start_of_app: f32 = @floatCast(engine().time.time_since_start_of_app());
            {
                const mapped_buffer = self.model_buffer.map(InstanceStruct, &engine().gfx) catch unreachable;
                defer mapped_buffer.unmap();

                for (0..Self.model_buffer_size) |i| {
                    if (top_model_idx + i >= self.skeletal_render_objects.items.len) break;
                    const iro = &self.skeletal_render_objects.items[top_model_idx + i].standard;

                    const entity_id = if (iro.entity_id) |e| e else 0;
                    mapped_buffer.data_array(Self.model_buffer_size)[i] = InstanceStruct {
                        .model_matrix = iro.transform,
                        .time = time_since_start_of_app,
                        .entity_id = entity_id,
                        .flags = .{
                            .is_selected = if (data.selected_entity_idx) |s| (entity_id == s) else false,
                        },
                    };
                }
            }

            top_model_idx += Self.model_buffer_size;
        }

        // Render the render object
        const instance_idx_buffer = &self.instance_index_buffers[self.instance_index_active_buffer];
        self.instance_index_active_buffer = (self.instance_index_active_buffer + 1) % 3;
        {
            const mapped_buffer = instance_idx_buffer.map(InstanceIdx, &engine().gfx) catch unreachable;
            defer mapped_buffer.unmap();
            mapped_buffer.data().instance_idx = @truncate(obj_idx + Self.model_buffer_size - top_model_idx);
            mapped_buffer.data().bone_start_idx = @truncate(sro.bone_info.bone_offset - start_bone_idx);
        }
        engine().gfx.cmd_set_constant_buffers(.Vertex, 3, &.{instance_idx_buffer});
        engine().gfx.cmd_set_constant_buffers(.Pixel, 3, &.{instance_idx_buffer});

        engine().gfx.cmd_set_vertex_buffers(0, ro.vertex_buffers.slice());

        if (ro.material.double_sided) {
            engine().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = true, });
        } else {
            engine().gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = false, });
        }

        var diffuse = &engine().gfx.default.diffuse;
        var diffuse_sampler = &engine().gfx.default.sampler;
        if (ro.material.diffuse_map) |*d| {
            diffuse = &d.map;
            if (d.sampler) |*s| { diffuse_sampler = s; }
        }
        engine().gfx.cmd_set_shader_resources(.Pixel, 0, &.{diffuse});
        engine().gfx.cmd_set_samplers(.Pixel, 0, &.{diffuse_sampler});

        if (ro.index_buffer) |ib| {
            engine().gfx.cmd_set_index_buffer(ib.buffer_info.buffer, .U32, 0);
            engine().gfx.cmd_draw_indexed(@truncate(ib.index_count), ib.buffer_info.offset, @intCast(ro.pos_offset));
        } else {
            engine().gfx.cmd_draw(@truncate(ro.vertex_count), 0);
        }
    }
}

