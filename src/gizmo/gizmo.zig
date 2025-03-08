const Self = @This();

const std = @import("std");
const engine = @import("engine");
const zm = engine.zmath;
const zmesh = engine.zmesh;
const gf = engine.gfx;
const input = engine.input;
const Transform = engine.Transform;
const SelectionTextures = @import("../selection_textures.zig");

const InstanceInfoStruct = extern struct {
    model_matrix: zm.Mat,
    colour: zm.F32x4,
    id: u32,
};

const RED = zm.srgbToRgb(zm.f32x4(0xF5, 0x6B, 0x4E, 0xFF) / zm.f32x4s(0xFF));
const GREEN = zm.srgbToRgb(zm.f32x4(0xB7, 0xF5, 0x4E, 0xFF) / zm.f32x4s(0xFF));
const BLUE = zm.srgbToRgb(zm.f32x4(0x4F, 0x80, 0xF5, 0xFF) / zm.f32x4s(0xFF));

torus_vertex_buffer: gf.Buffer,
torus_index_buffer: gf.Buffer,
torus_index_count: usize,

cylinder_vertex_buffer: gf.Buffer,
cylinder_index_buffer: gf.Buffer,
cylinder_index_count: usize,

vertex_shader: gf.VertexShader,
pixel_shader: gf.PixelShader,

instance_data_buffer: gf.Buffer,
selection_textures: SelectionTextures,

pub fn deinit(self: *Self) void {
    self.torus_vertex_buffer.deinit();
    self.torus_index_buffer.deinit();

    self.vertex_shader.deinit();
    self.pixel_shader.deinit();

    self.instance_data_buffer.deinit();
    self.selection_textures.deinit();
}

pub fn init(alloc: std.mem.Allocator, gfx: *gf.GfxState) !Self {
    const torus_shape = zmesh.Shape.initTorus(16, 64, 0.05);
    defer torus_shape.deinit();

    const torus_vertex_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(torus_shape.positions),
        .{ .VertexBuffer = true, },
        .{},
        gfx
    );
    errdefer torus_vertex_buffer.deinit();

    const torus_index_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(torus_shape.indices),
        .{ .IndexBuffer = true, },
        .{},
        gfx
    );
    errdefer torus_index_buffer.deinit();

    const cylinder_shape = zmesh.Shape.initCylinder(16, 2);
    defer cylinder_shape.deinit();

    const cylinder_vertex_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(cylinder_shape.positions),
        .{ .VertexBuffer = true, },
        .{},
        gfx
    );
    errdefer cylinder_vertex_buffer.deinit();

    const cylinder_index_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(cylinder_shape.indices),
        .{ .IndexBuffer = true, },
        .{},
        gfx
    );
    errdefer cylinder_index_buffer.deinit();

    const instance_data_buffer = try gf.Buffer.init(
        @sizeOf(InstanceInfoStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        gfx
    );
    errdefer instance_data_buffer.deinit();

    var selection_textures = try SelectionTextures.init(gfx);
    errdefer selection_textures.deinit();

    var self = Self {
        .torus_vertex_buffer = torus_vertex_buffer,
        .torus_index_buffer = torus_index_buffer,
        .torus_index_count = torus_shape.indices.len,
        .cylinder_vertex_buffer = cylinder_vertex_buffer,
        .cylinder_index_buffer = cylinder_index_buffer,
        .cylinder_index_count = cylinder_shape.indices.len,
        .instance_data_buffer = instance_data_buffer,
        .selection_textures = selection_textures,
        .vertex_shader = undefined,
        .pixel_shader = undefined,
    };

    self.compile_shaders(alloc, gfx) catch |err| {
        std.log.err("unable to compile shaders: {}", .{err});
        return err;
    };
    errdefer {
        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
    }

    return self;
}

fn compile_shaders(self: *Self, alloc: std.mem.Allocator, gfx: *gf.GfxState) !void {
    var res = true;
    const maybe_vertex_shader = gf.VertexShader.init_file(
        alloc,
        .{ .ExeRelative = "../../src/gizmo/gizmo.hlsl" },
        "vs_main",
        (&[_]gf.VertexInputLayoutEntry {
            .{ .name = "POS",                   .format = .F32x3,   .per = .Vertex, .slot = 0, },
        }),
        .{},
        gfx
    ); 
    if (maybe_vertex_shader) |vertex_shader| {
        self.vertex_shader = vertex_shader;
    } else |err| {
        std.log.err("unable to compile vertex shader: {}", .{err});
        res = false;
    }

    const maybe_pixel_shader = gf.PixelShader.init_file(
        alloc,
        .{ .ExeRelative = "../../src/gizmo/gizmo.hlsl" },
        "ps_main",
        .{},
        gfx
    );
    if (maybe_pixel_shader) |pixel_shader| {
        self.pixel_shader = pixel_shader;
    } else |err| {
        std.log.err("unable to compile pixel shader: {}", .{err});
        res = false;
    }
    
    if (!res) {
        return error.ShaderCompilationFailed;
    }
}

const GizmoControl = enum(u32) {
    None = 0,
    TranslateX,
    TranslateY,
    TranslateZ,
    RotateX,
    RotateY,
    RotateZ,
};

fn sub_rotation(control: GizmoControl, base_rot: *const zm.Mat, base_translation: *const zm.Mat) zm.Mat {
    const subrot = switch (control) {
        .TranslateX, .RotateX => zm.rotationY(std.math.pi * 0.5),
        .TranslateY, .RotateY => zm.rotationX(std.math.pi * 0.5),
        .TranslateZ, .RotateZ, .None => zm.identity(),
    };
    
    return zm.mul(
        zm.mul(subrot, base_rot.*), 
        base_translation.*
    );
}

pub fn update_and_render(self: *Self, transform: *Transform, camera_buffer: *gf.Buffer, rtv: *gf.RenderTargetView, dsv: *gf.DepthStencilView, gfx: *gf.GfxState, in: *input.InputState) void {
    if (in.get_key(input.KeyCode.MouseLeft)) {
        if (self.selection_textures.get_value_at_position(@intCast(in.cursor_position[0]), @intCast(in.cursor_position[1]), gfx)) |s| {
            std.log.info("selection: {}", .{s});
            switch (@as(GizmoControl, @enumFromInt(s))) {
                .None => {},
                .TranslateX => transform.position += transform.right_direction() * zm.f32x4s(in.mouse_delta[0]),
                .TranslateY => {},
                .TranslateZ => {},
                .RotateX => {},
                .RotateY => {},
                .RotateZ => {},
            }
        } else |err| {
            std.log.err("cannot get value at position: {}", .{err});
        }
    }

    // recreate selection textures if size has changed
    if (self.selection_textures.texture.desc.width != gfx.swapchain_size.width or self.selection_textures.texture.desc.height != gfx.swapchain_size.height) {
        self.selection_textures.on_resize(gfx);
    }

    gfx.cmd_clear_depth_stencil_view(dsv, 0.0, null);
    gfx.cmd_clear_render_target(&self.selection_textures.rtv, zm.f32x4s(0.0));
    gfx.cmd_set_render_target(&.{rtv, &self.selection_textures.rtv}, dsv);

    // set shaders
    gfx.cmd_set_vertex_shader(&self.vertex_shader);
    gfx.cmd_set_pixel_shader(&self.pixel_shader);

    // set render state
    gfx.cmd_set_blend_state(null);
    gfx.cmd_set_topology(.TriangleList);
    gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = true, });

    // set shader resources
    gfx.cmd_set_constant_buffers(.Vertex, 0, &[_]*const gf.Buffer{
        camera_buffer,
        &self.instance_data_buffer,
    });
    gfx.cmd_set_constant_buffers(.Pixel, 0, &[_]*const gf.Buffer{
        camera_buffer,
        &self.instance_data_buffer,
    });

    // set torus vertex and index buffers
    gfx.cmd_set_vertex_buffers(0, &[_]gf.VertexBufferInput{
        .{ .buffer = &self.torus_vertex_buffer, .stride = @sizeOf([3]f32), .offset = 0, },
    });
    gfx.cmd_set_index_buffer(&self.torus_index_buffer, .U32, 0);

    const base_rot = zm.matFromQuat(transform.rotation);
    const base_tra = zm.translationV(transform.position);

    // render red torus
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data().* = .{
            .model_matrix = sub_rotation(GizmoControl.RotateX, &base_rot, &base_tra),
            .colour = RED,
            .id = @intFromEnum(GizmoControl.RotateX),
        };
    }
    gfx.cmd_draw_indexed(@intCast(self.torus_index_count), 0, 0);

    // render green torus
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data().* = .{
            .model_matrix = sub_rotation(GizmoControl.RotateY, &base_rot, &base_tra),
            .colour = GREEN,
            .id = @intFromEnum(GizmoControl.RotateY),
        };
    }
    gfx.cmd_draw_indexed(@intCast(self.torus_index_count), 0, 0);

    // render blue torus
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data().* = .{
            .model_matrix = sub_rotation(GizmoControl.RotateZ, &base_rot, &base_tra),
            .colour = BLUE,
            .id = @intFromEnum(GizmoControl.RotateZ),
        };
    }
    gfx.cmd_draw_indexed(@intCast(self.torus_index_count), 0, 0);


    // set culinder vertex and index buffers
    gfx.cmd_set_vertex_buffers(0, &[_]gf.VertexBufferInput{
        .{ .buffer = &self.cylinder_vertex_buffer, .stride = @sizeOf([3]f32), .offset = 0, },
    });
    gfx.cmd_set_index_buffer(&self.cylinder_index_buffer, .U32, 0);

    const scale_mat = zm.scalingV(zm.f32x4(0.05, 0.05, 1.0, 1.0));

    // render red cylinder
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data().* = .{
            .model_matrix = zm.mul(scale_mat, sub_rotation(GizmoControl.TranslateX, &base_rot, &base_tra)),
            .colour = RED,
            .id = @intFromEnum(GizmoControl.TranslateX),
        };
    }
    gfx.cmd_draw_indexed(@intCast(self.cylinder_index_count), 0, 0);

    // render green cylinder
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data().* = .{
            .model_matrix = zm.mul(scale_mat, sub_rotation(GizmoControl.TranslateY, &base_rot, &base_tra)),
            .colour = GREEN,
            .id = @intFromEnum(GizmoControl.TranslateY),
        };
    }
    gfx.cmd_draw_indexed(@intCast(self.cylinder_index_count), 0, 0);

    // render blue cylinder
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data().* = .{
            .model_matrix = zm.mul(scale_mat, sub_rotation(GizmoControl.TranslateZ, &base_rot, &base_tra)),
            .colour = BLUE,
            .id = @intFromEnum(GizmoControl.TranslateZ),
        };
    }
    gfx.cmd_draw_indexed(@intCast(self.cylinder_index_count), 0, 0);
}
