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

    pub fn init(alloc: std.mem.Allocator) !HealthPointComponent {
        _ = alloc;
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

    pub fn editor_ui(imui: *eng.ui, component: *HealthPointComponent, key: anytype) !void {
        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};

pub const AnimControllerComponent = struct {
    anim_controller: eng.animation.AnimController,

    pub fn deinit(self: *AnimControllerComponent) void {
        self.anim_controller.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !AnimControllerComponent {
        const anim_controller = try eng.animation.AnimController.init(alloc);
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
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        const anim_controller = try sr.deserialize_value(eng.animation.AnimController, alloc, object.get("anim_controller"));
        errdefer anim_controller.deinit();

        return AnimControllerComponent {
            .anim_controller = anim_controller,
        };
    }
    
    pub fn editor_ui(imui: *eng.ui, component: *AnimControllerComponent, key: anytype) !void {
        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};

pub const ParticleSystemComponent = struct {
    particle_system: eng.particles.ParticleSystem,

    pub fn deinit(self: *ParticleSystemComponent) void {
        self.particle_system.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !ParticleSystemComponent {
        const particle_system = try eng.particles.ParticleSystem.init(alloc, .{});
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
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        var particle_system_settings = try sr.deserialize_value(eng.particles.ParticleSystemSettings, alloc, object.get("particle_system_settings"));
        defer particle_system_settings.deinit(alloc);

        const particle_system = try eng.particles.ParticleSystem.init(alloc, particle_system_settings);
        errdefer particle_system.deinit();
        
        return ParticleSystemComponent {
            .particle_system = particle_system,
        };
    }

    pub fn editor_ui(imui: *eng.ui, component: *ParticleSystemComponent, key: anytype) !void {
        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};

pub const LightComponent = struct {
    light: StandardRenderer.Light,

    pub fn deinit(self: *LightComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !LightComponent {
        _ = alloc;
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
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        const light = try sr.deserialize_value(StandardRenderer.Light, alloc, object.get("light"));

        return LightComponent {
            .light = light,
        };
    }

    pub fn editor_ui(imui: *eng.ui, component: *LightComponent, key: anytype) !void {
        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};

pub const TerrainComponent = struct {
    terrain: Terrain,

    pub fn deinit(self: *TerrainComponent) void {
        self.terrain.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !TerrainComponent {
        const terrain = try Terrain.init(alloc);
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
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        const terrain = try sr.deserialize_value(Terrain, alloc, object.get("terrain"));
        errdefer terrain.deinit();

        return TerrainComponent {
            .terrain = terrain,
        };
    }
    
    pub fn editor_ui(imui: *eng.ui, component: *TerrainComponent, key: anytype) !void {
        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};

pub const CloudVolumeComponent = struct {
    int: u32 = 0,

    pub fn deinit(self: *CloudVolumeComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !CloudVolumeComponent {
        _ = alloc;
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

    pub fn editor_ui(imui: *eng.ui, component: *CloudVolumeComponent, key: anytype) !void {
        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};
