const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;
const Terrain = @import("terrain.zig");
const Transform = eng.Transform;
const st = @import("../selection_textures.zig");

const HeightFieldModelSize = 16;

const InstanceInfoStruct = extern struct {
    origin: zm.F32x4,
    size: zm.F32x4,
};

instance_data_buffer: gf.Buffer,

vertex_shader: gf.VertexShader,
pixel_shader: gf.PixelShader,

selection_textures: st.SelectionTextures([2]f32),

model: eng.mesh.Model,

pub fn deinit(self: *Self) void {
    self.instance_data_buffer.deinit();
    self.vertex_shader.deinit();
    self.pixel_shader.deinit();
    self.selection_textures.deinit();
    self.model.deinit();
}

pub fn init(alloc: std.mem.Allocator, gfx: *gf.GfxState) !Self {
    var plane_model = try eng.mesh.Model.plane(alloc, HeightFieldModelSize - 1, HeightFieldModelSize - 1, gfx);
    errdefer plane_model.deinit();

    const instance_data_buffer = try gf.Buffer.init(
        @sizeOf(InstanceInfoStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
        gfx
    );
    errdefer instance_data_buffer.deinit();

    var selection_textures = try st.SelectionTextures([2]f32).init(gfx);
    errdefer selection_textures.deinit();

    var self = Self {
        .model = plane_model,
        .instance_data_buffer = instance_data_buffer,
        .vertex_shader = undefined,
        .pixel_shader = undefined,
        .selection_textures = selection_textures,
    };

    const shaders = try self.compile_shaders(alloc, gfx);
    errdefer self.deinit();

    self.vertex_shader = shaders.vertex_shader;
    self.pixel_shader = shaders.pixel_shader;

    return self;
}

fn compile_shaders(self: *Self, alloc: std.mem.Allocator, gfx: *gf.GfxState) !struct {
    vertex_shader: gf.VertexShader,
    pixel_shader: gf.PixelShader,
} {
    _ = self;
    const new_vertex_shader = try gf.VertexShader.init_file(
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
    errdefer new_vertex_shader.deinit();

    const new_pixel_shader = try gf.PixelShader.init_file(
        alloc,
        .{ .ExeRelative = "../../src/terrain/terrain.hlsl" },
        "ps_main",
        .{},
        gfx
    );
    errdefer new_pixel_shader.deinit();
    
    return .{
        .vertex_shader = new_vertex_shader,
        .pixel_shader = new_pixel_shader,
    };
}

/// Render the terrain using the camera buffer
pub fn render(
    self: *Self, 
    camera_buffer: *const gf.Buffer, 
    transform: Transform, 
    terrain: *const Terrain, 
    rtv: *const gf.RenderTargetView,
    dsv: *const gf.DepthStencilView,
    gfx: *gf.GfxState
) void {
    // update instance data buffer
    {
        const mapped_buffer = self.instance_data_buffer.map(InstanceInfoStruct, gfx) catch unreachable;
        defer mapped_buffer.unmap();
        mapped_buffer.data().origin = transform.position;
        mapped_buffer.data().size = 
            zm.f32x4(terrain.terrain_size[0], 1.0, terrain.terrain_size[1], 1.0);
    }

    self.selection_textures.clear(gfx, [2]f32{ 0.0, 0.0 });
    gfx.cmd_set_render_target(&.{ rtv, &self.selection_textures.rtv }, dsv);

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
        terrain.heightmap_texture_view,
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
