const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;

const HeightFieldSize = 16;

alloc: std.mem.Allocator,

origin: zm.F32x4 = zm.f32x4(0.0, -1.0, 0.0, 0.0),

model: eng.mesh.Model,

heightmap: []f32,

heightmap_texture: gf.Texture2D,
heightmap_texture_view: gf.TextureView2D,

physics_system: *eng.physics.PhysicsSystem,
physics_body_id: ?ph.zphy.BodyId = null,

pub fn deinit(self: *Self) void {
    self.model.deinit();
    self.heightmap_texture.deinit();
    self.heightmap_texture_view.deinit();
    self.remove_physics_body();
    self.alloc.free(self.heightmap);
}

pub fn init(alloc: std.mem.Allocator, physics: *eng.physics.PhysicsSystem, gfx: *gf.GfxState) !Self {
    var plane_model = try eng.mesh.Model.plane(alloc, HeightFieldSize, HeightFieldSize, gfx);
    errdefer plane_model.deinit();

    const heightmap_texture = try gf.Texture2D.init(
        .{
            .height = HeightFieldSize,
            .width = HeightFieldSize,
            .format = .R32_Float,
        },
        .{ .ShaderResource = true, },
        .{ .CpuWrite = true, },
        null,
        gfx
    );
    errdefer heightmap_texture.deinit();

    const heightmap_texture_view = try gf.TextureView2D.init_from_texture2d(&heightmap_texture, gfx);
    errdefer heightmap_texture_view.deinit();

    const heightmap_data = try alloc.alloc(f32, HeightFieldSize * HeightFieldSize);
    errdefer alloc.free(heightmap_data);

    for (0..HeightFieldSize) |y| {
        for (0..HeightFieldSize) |x| {
            const u: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(HeightFieldSize));
            const v: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(HeightFieldSize));
            heightmap_data[y * HeightFieldSize + x] = std.math.sin(u * std.math.pi * 2.0) * std.math.sin(v * std.math.pi * 2.0);
        }
    }

    var self = Self {
        .alloc = alloc,
        .model = plane_model,
        .heightmap_texture = heightmap_texture,
        .heightmap_texture_view = heightmap_texture_view,
        .heightmap = heightmap_data,
        .physics_system = physics,
    };
    errdefer self.deinit();

    try self.generate_heightmap_physics();

    return self;
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
