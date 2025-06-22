const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;
const as = eng.assets;
const Terrain = @import("terrain.zig");
const Transform = eng.Transform;
const st = @import("../selection_textures.zig");
const pt = eng.path;

const HeightFieldModelSize = 32;

const InstanceInfoStruct = extern struct {
    origin: zm.F32x4,
    height_scale: f32,
    grid_length: f32,
    grid_scale: f32,
    _pad0: f32 = 0.0,
    modify_cells: zm.F32x4,
    modify_center: [2]f32 = [_]f32{ 0.0, 0.0 },
    modify_radius: f32 = 0.0,
    modify_strength: f32 = 0.0,
};

instance_data_buffer: gf.Buffer.Ref,

vertex_shader: gf.VertexShader,
pixel_shader: gf.PixelShader,
watch: eng.assets.FileWatcher,

selection_textures: st.SelectionTextures([2]f32),

model: eng.mesh.Model,

pub fn deinit(self: *Self) void {
    self.instance_data_buffer.deinit();
    self.vertex_shader.deinit();
    self.pixel_shader.deinit();
    self.selection_textures.deinit();
    self.model.deinit();
    self.watch.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    var plane_model = try eng.mesh.Model.plane(alloc, HeightFieldModelSize * 2 - 2, HeightFieldModelSize * 2 - 2);
    errdefer plane_model.deinit();

    const instance_data_buffer = try gf.Buffer.init(
        @sizeOf(InstanceInfoStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer instance_data_buffer.deinit();

    var selection_textures = try st.SelectionTextures([2]f32).init();
    errdefer selection_textures.deinit();

    const terrain_path = try pt.Path.init(eng.get().general_allocator, .{ .ExeRelative = "../../src/terrain/terrain.hlsl" });
    defer terrain_path.deinit();

    const terrain_path_abs = try terrain_path.resolve_path(alloc);
    defer alloc.free(terrain_path_abs);

    var self = Self {
        .model = plane_model,
        .instance_data_buffer = instance_data_buffer,
        .vertex_shader = undefined,
        .pixel_shader = undefined,
        .selection_textures = selection_textures,
        .watch = try eng.assets.FileWatcher.init(alloc, terrain_path_abs, 500),
    };

    const shaders = try self.compile_shaders(alloc);
    errdefer self.deinit();

    self.vertex_shader = shaders.vertex_shader;
    self.pixel_shader = shaders.pixel_shader;

    return self;
}

fn compile_shaders(self: *Self, alloc: std.mem.Allocator) !struct {
    vertex_shader: gf.VertexShader,
    pixel_shader: gf.PixelShader,
} {
    _ = self;
    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = "../../src/terrain/terrain.hlsl" });
    defer path.deinit();

    const new_vertex_shader = try gf.VertexShader.init_file(
        alloc,
        path,
        "vs_main",
        .{
            .bindings = &.{
                .{ .binding = 0, .stride = 20, .input_rate = .Vertex, },
            },
            .attributes = &.{
                .{ .name = "POS",           .location = 0, .binding = 0, .offset = 0,  .format = .F32x3, },
                .{ .name = "TEXCOORD0",     .location = 1, .binding = 0, .offset = 12, .format = .F32x2, },
            },
        },
        .{},
    );
    errdefer new_vertex_shader.deinit();

    const new_pixel_shader = try gf.PixelShader.init_file(
        alloc,
        path,
        "ps_main",
        .{},
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
    rtv: gf.ImageView.Ref,
    dsv: gf.ImageView.Ref,
) void {
    if (self.watch.was_modified_since_last_check()) blk: {
        const shaders = self.compile_shaders(eng.get().general_allocator) catch break :blk;
        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.vertex_shader = shaders.vertex_shader;
        self.pixel_shader = shaders.pixel_shader;
    }

    // update instance data buffer
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .origin = transform.position,
            .height_scale = terrain.height_scale,
            .grid_length = @as(f32, @floatFromInt(HeightFieldModelSize)),
            .grid_scale = terrain.terrain_grid_scale,
            .modify_cells = zm.f32x4(
                terrain.dbg_modify_cells[0][0], 
                terrain.dbg_modify_cells[0][1], 
                terrain.dbg_modify_cells[1][0], 
                terrain.dbg_modify_cells[1][1]),
            .modify_center = terrain.dbg_modify_center,
            .modify_radius = terrain.modify_radius,
            .modify_strength = 1.0,
        };
    }

    const gfx = gf.GfxState.get();

    self.selection_textures.clear([2]f32{ -1.0, -1.0 });
    gfx.cmd_set_render_target(&.{ rtv, self.selection_textures.rtv }, dsv);

    // set shaders
    gfx.cmd_set_vertex_shader(&self.vertex_shader);
    gfx.cmd_set_pixel_shader(&self.pixel_shader);

    // set render state
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

    const texture_id = eng.get().asset_manager.find_asset_id(as.ImageAsset, "default|terrain-texture").?;
    const texture = eng.get().asset_manager.get_asset(as.ImageAsset, texture_id) catch unreachable;

    const texture_view = gf.ImageView.init(.{ .image = texture.*, }) catch unreachable;
    defer texture_view.deinit();

    gfx.cmd_set_shader_resources(.Vertex, 0, &.{
        terrain.heightmap_texture_view,
        //texture_view,
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
