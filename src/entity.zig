const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;
const StandardRenderer = @import("render.zig");
const Terrain = @import("terrain/terrain.zig");

pub const HealthPointComponent = struct {
    health_points: i32 = 0,

    pub fn deinit(self: *HealthPointComponent) void {
        _ = self;
    }

    pub fn init() !HealthPointComponent {
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: HealthPointComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("health_points", try sr.serialize_value(i32, alloc, value.health_points));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !HealthPointComponent {
        var component: HealthPointComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.health_points = try sr.deserialize_value(i32, alloc, object.get("health_points"));

        return component;
    }
};

pub const AnimControllerComponent = struct {
    anim_controller: eng.animation.AnimController,

    pub fn deinit(self: *AnimControllerComponent) void {
        self.anim_controller.deinit();
    }

    pub fn init() !AnimControllerComponent {
        const anim_controller = try eng.animation.AnimController.init(eng.get().general_allocator);
        errdefer anim_controller.deinit();

        return .{
            .anim_controller = anim_controller,
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: AnimControllerComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("anim_controller", try sr.serialize_value(eng.animation.AnimController, alloc, value.anim_controller));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !AnimControllerComponent {
        var component: AnimControllerComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.anim_controller = try sr.deserialize_value(eng.animation.AnimController, alloc, object.get("anim_controller"));

        return component;
    }
};

pub const ParticleSystemComponent = struct {
    particle_system: eng.particles.ParticleSystem,

    pub fn deinit(self: *ParticleSystemComponent) void {
        self.particle_system.deinit();
    }

    pub fn init() !ParticleSystemComponent {
        const particle_system = try eng.particles.ParticleSystem.init(eng.get().general_allocator, .{});
        errdefer particle_system.deinit();

        return .{
            .particle_system = particle_system,
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: ParticleSystemComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("particle_system_settings", try sr.serialize_value(eng.particles.ParticleSystemSettings, alloc, value.particle_system.settings));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !ParticleSystemComponent {
        var component: ParticleSystemComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        var particle_system_settings: eng.particles.ParticleSystemSettings = .{};
        defer if (particle_system_settings) |*pss| pss.deinit(alloc);
        particle_system_settings = try sr.deserialize_value(eng.particles.ParticleSystemSettings, alloc, object.get("particle_system_settings"));

        if (particle_system_settings) |settings| {
            component.particle_system = try eng.particles.ParticleSystem.init(alloc, settings);
        }
        errdefer component.particle_system.deinit();
        
        return component;
    }
};

pub const LightComponent = struct {
    light: StandardRenderer.Light,

    pub fn deinit(self: *LightComponent) void {
        _ = self;
    }

    pub fn init() !LightComponent {
        return .{
            .light = .{},
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: LightComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("light", try sr.serialize_value(StandardRenderer.Light, alloc, value.light));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !LightComponent {
        var component: LightComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.light = try sr.deserialize_value(StandardRenderer.Light, alloc, object.get("light"));

        return component;
    }
};

pub const TerrainComponent = struct {
    terrain: Terrain,

    pub fn deinit(self: *TerrainComponent) void {
        self.terrain.deinit();
    }

    pub fn init() !TerrainComponent {
        const terrain = try Terrain.init(eng.get().general_allocator);
        errdefer terrain.deinit();

        return .{
            .terrain = terrain,
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: TerrainComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("terrain", try sr.serialize_value(Terrain, alloc, value.terrain));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !TerrainComponent {
        var component: TerrainComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.terrain = sr.deserialize_value(Terrain, alloc, object.get("terrain"));
        errdefer component.terrain.deinit();

        return component;
    }
};

pub const CloudVolumeComponent = struct {
    int: u32 = 0,

    pub fn deinit(self: *CloudVolumeComponent) void {
        _ = self;
    }

    pub fn init() !CloudVolumeComponent {
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: CloudVolumeComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("int", try sr.serialize_value(u32, alloc, value.int));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !CloudVolumeComponent {
        var component: CloudVolumeComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.int = try sr.deserialize_value(u32, alloc, object.get("int"));

        return component;
    }
};
