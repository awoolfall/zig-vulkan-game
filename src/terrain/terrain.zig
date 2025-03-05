const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;

const HeightFieldSize = 16;

const InstanceInfoStruct = extern struct {
    origin: zm.F32x4,
};

alloc: std.mem.Allocator,

origin: zm.F32x4 = zm.f32x4(5.0, 1.0, 5.0, 0.0),
instance_data_buffer: gf.Buffer,

vertex_shader: gf.VertexShader,
pixel_shader: gf.PixelShader,

model: eng.mesh.Model,

heightmap: []f32,

heightmap_texture: gf.Texture2D,
heightmap_texture_view: gf.TextureView2D,

physics_system: *eng.physics.PhysicsSystem,
physics_body_id: ?ph.zphy.BodyId = null,

pub fn deinit(self: *Self) void {
    self.instance_data_buffer.deinit();
    self.vertex_shader.deinit();
    self.pixel_shader.deinit();
    self.model.deinit();
    self.heightmap_texture.deinit();
    self.heightmap_texture_view.deinit();
    self.remove_physics_body();
    self.alloc.free(self.heightmap);
}

pub fn init(alloc: std.mem.Allocator, physics: *eng.physics.PhysicsSystem, gfx: *gf.GfxState) !Self {
    var plane_model = try eng.mesh.Model.plane(alloc, HeightFieldSize - 1, HeightFieldSize - 1, gfx);
    errdefer plane_model.deinit();

    const heightmap_data = try alloc.alloc(f32, HeightFieldSize * HeightFieldSize);
    errdefer alloc.free(heightmap_data);

    for (0..HeightFieldSize) |y| {
        for (0..HeightFieldSize) |x| {
            const u: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(HeightFieldSize - 1));
            const v: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(HeightFieldSize - 1));
            heightmap_data[y * HeightFieldSize + x] = std.math.sin(u * std.math.pi * 2.0) * std.math.sin(v * std.math.pi * 2.0);
        }
    }

    const heightmap_texture = try gf.Texture2D.init(
        .{
            .height = HeightFieldSize,
            .width = HeightFieldSize,
            .format = .R32_Float,
        },
        .{ .ShaderResource = true, },
        .{ .CpuWrite = true, },
        std.mem.sliceAsBytes(heightmap_data),
        gfx
    );
    errdefer heightmap_texture.deinit();

    const heightmap_texture_view = try gf.TextureView2D.init_from_texture2d(&heightmap_texture, gfx);
    errdefer heightmap_texture_view.deinit();

    const instance_data_buffer = try gf.Buffer.init(
        @sizeOf(InstanceInfoStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        gfx
    );
    errdefer instance_data_buffer.deinit();

    var self = Self {
        .alloc = alloc,
        .model = plane_model,
        .heightmap_texture = heightmap_texture,
        .heightmap_texture_view = heightmap_texture_view,
        .heightmap = heightmap_data,
        .physics_system = physics,
        .instance_data_buffer = instance_data_buffer,
        .vertex_shader = undefined,
        .pixel_shader = undefined,
    };
    try self.compile_shaders(alloc, gfx);
    errdefer self.deinit();

    try self.generate_heightmap_physics();

    return self;
}

fn compile_shaders(self: *Self, alloc: std.mem.Allocator, gfx: *gf.GfxState) !void {
    var res = true;
    const maybe_vertex_shader = gf.VertexShader.init_file(
        alloc,
        .{ .ExeRelative = "../../src/terrain/terrain.hlsl" },
        "vs_main",
        (&[_]gf.VertexInputLayoutEntry {
            .{ .name = "POS",                   .format = .F32x3,   .per = .Vertex, .slot = 0, },
            .{ .name = "TEXCOORD",              .format = .F32x2,   .per = .Vertex, .slot = 1, },
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
        .{ .ExeRelative = "../../src/terrain/terrain.hlsl" },
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

/// Removes the physics body from the terrain if it exists
fn remove_physics_body(self: *Self) void {
    if (self.physics_body_id) |*b| {
        const body_interface = self.physics_system.zphy.getBodyInterfaceMut();
        body_interface.removeAndDestroyBody(b.*);
        self.physics_body_id = null;
    }
}

/// Regenerates the heightmap physics body using the internal heightmap data
fn generate_heightmap_physics(self: *Self) !void {
    const body_interface = self.physics_system.zphy.getBodyInterfaceMut();

    // create the new physics body
    const shape_settings = try ph.zphy.HeightFieldShapeSettings.create(self.heightmap.ptr, HeightFieldSize);
    defer shape_settings.release();

    const shape = try shape_settings.createShape();
    defer shape.release();

    const new_body = try body_interface.createAndAddBody(.{
        .shape = shape,
        .position = self.origin,
        .motion_type = .static,
    }, .activate);
    errdefer body_interface.removeAndDestroyBody(new_body);

    // Remove body if it exists
    self.remove_physics_body();
    
    // apply new physics body
    self.physics_body_id = new_body;
}

/// Render the terrain using the camera buffer
pub fn render(self: *Self, camera_buffer: *const gf.Buffer, gfx: *gf.GfxState) void {
    // update instance data buffer
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();
        mapped_buffer.data().origin = self.origin;
    }

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
    gfx.cmd_set_shader_resources(.Vertex, 0, .{
        self.heightmap_texture_view,
    });

    // set vertex and index buffers
    var m = self.model;
    gfx.cmd_set_vertex_buffers(0, &[_]gf.VertexBufferInput{
        .{ .buffer = &m.buffers.vertices, .stride = @truncate(m.buffers.strides.positions), .offset = @truncate(m.buffers.offsets.positions), },
        .{ .buffer = &m.buffers.vertices, .stride = @truncate(m.buffers.strides.texcoords), .offset = @truncate(m.buffers.offsets.texcoords), },
        .{ .buffer = &m.buffers.vertices, .stride = @truncate(m.buffers.strides.normals), .offset = @truncate(m.buffers.offsets.normals), },
    });
    gfx.cmd_set_index_buffer(&m.buffers.indices, .U32, 0);

    // draw
    const p = m.mesh_list[0];
    gfx.cmd_draw_indexed(@intCast(p.num_indices), @intCast(p.indices_offset), @intCast(p.pos_offset));
}
