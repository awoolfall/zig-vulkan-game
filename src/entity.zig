const Self = @This();

const std = @import("std");
const eng = @import("engine");
const StandardRenderer = @import("render.zig");
const Terrain = @import("terrain/terrain.zig");

health_points: ?i32 = null,
anim_controller: ?eng.animation.AnimController = null,
particle_system: ?eng.particles.ParticleSystem = null,
light: ?StandardRenderer.Light = null,
terrain: ?Terrain = null,

pub fn deinit(self: *Self) void {
    if (self.anim_controller) |*anim_controller| {
        anim_controller.deinit();
    }
    if (self.particle_system) |*particle_system| {
        particle_system.deinit();
    }
    if (self.terrain) |*terrain| {
        terrain.deinit();
    }
}

pub fn serialize(alloc: std.mem.Allocator, self: Self) !std.json.Value {
    var object = std.json.ObjectMap.init(alloc);
    errdefer object.deinit();

    try object.put("health_points", try eng.serialize.serialize_value(?i32, alloc, self.health_points));
    try object.put("anim_constroller", try eng.serialize.serialize_value(?eng.animation.AnimController, alloc, self.anim_controller));
    try object.put("particle_system_settings", try eng.serialize.serialize_value(?eng.particles.ParticleSystemSettings, alloc, if (self.particle_system) |ps| ps.settings else null));
    try object.put("light", try eng.serialize.serialize_value(?StandardRenderer.Light, alloc, self.light));
    try object.put("terrain", try eng.serialize.serialize_value(?Terrain, alloc, self.terrain));

    return std.json.Value { .object = object };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    var self = Self {};
    errdefer self.deinit();

    const object: *const std.json.ObjectMap = switch (value) { .object => |obj| &obj, else => return error.InvalidType, };

    if (object.get("health_points")) |v| blk: { self.health_points = eng.serialize.deserialize_value(?i32, alloc, v) catch break :blk; }

    if (object.get("anim_controller")) |v| blk: { self.anim_controller = eng.serialize.deserialize_value(?eng.animation.AnimController, alloc, v) catch break :blk; }
    errdefer if (self.anim_controller) |*a| { a.deinit(); };

    var particle_system_settings: ?eng.particles.ParticleSystemSettings = null;
    if (object.get("particle_system_settings")) |v| blk: { particle_system_settings = eng.serialize.deserialize_value(?eng.particles.ParticleSystemSettings, alloc, v) catch break :blk; }

    if (particle_system_settings) |settings| {
        self.particle_system = try eng.particles.ParticleSystem.init(alloc, settings);
    }
    errdefer if (self.particle_system) |*ps| { ps.deinit(); };

    if (object.get("light")) |v| blk: { self.light = eng.serialize.deserialize_value(?StandardRenderer.Light, alloc, v) catch break :blk; }

    if (object.get("terrain")) |v| blk: { self.terrain = eng.serialize.deserialize_value(?Terrain, alloc, v) catch break :blk; }
    errdefer if (self.terrain) |*t| { t.deinit(); };

    return self;
}
