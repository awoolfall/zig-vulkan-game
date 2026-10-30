const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

pub const COMPONENT_UUID = "838230f5-64a2-4d94-9fdf-1eadb584ad4d";
pub const COMPONENT_NAME = "Particle System";

const Self = @This();

particle_system: eng.ParticleSystem,

pub fn deinit(self: *Self) void {
    self.particle_system.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const particle_system = try eng.ParticleSystem.init(alloc, .{});
    errdefer particle_system.deinit();

    return .{
        .particle_system = particle_system,
    };
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try sr.serialize_object_value(alloc, object, eng.ParticleSystem.ParticleSystemSettings, "particle_system_settings", self.particle_system.settings);
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    var particle_system_settings = try sr.deserialize_object_value(alloc, &object, eng.ParticleSystem.ParticleSystemSettings, "particle_system_settings") orelse eng.ParticleSystem.ParticleSystemSettings{};
    defer particle_system_settings.deinit(alloc);

    const particle_system = try eng.ParticleSystem.init(alloc, particle_system_settings);
    errdefer particle_system.deinit();

    return Self{
        .particle_system = particle_system,
    };
}

pub fn editor_ui(imui: *eng.Imui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = entity;

    _ = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    {
        // TODO
        _ = component;
    }
}
