const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

pub const COMPONENT_UUID = "838230f5-64a2-4d94-9fdf-1eadb584ad4d";
pub const COMPONENT_NAME = "Particle System";

const Self = @This();

particle_system: eng.particles.ParticleSystem,

pub fn deinit(self: *Self) void {
    self.particle_system.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const particle_system = try eng.particles.ParticleSystem.init(alloc, .{});
    errdefer particle_system.deinit();

    return .{
        .particle_system = particle_system,
    };
}

pub fn serialize(alloc: std.mem.Allocator, value: Self) !std.json.Value {
    var object = std.json.ObjectMap.init(alloc);
    errdefer object.deinit();

    try object.put("particle_system_settings", try sr.serialize_value(eng.particles.ParticleSystemSettings, alloc, value.particle_system.settings));

    return std.json.Value { .object = object };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

    var particle_system_settings = try sr.deserialize_value(eng.particles.ParticleSystemSettings, alloc, object.get("particle_system_settings"));
    defer particle_system_settings.deinit(alloc);

    const particle_system = try eng.particles.ParticleSystem.init(alloc, particle_system_settings);
    errdefer particle_system.deinit();
    
    return Self {
        .particle_system = particle_system,
    };
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = entity;

    _ = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    {
        // TODO
        _ = component;
    }
}
