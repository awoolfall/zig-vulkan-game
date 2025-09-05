const Self = @This();

const std = @import("std");
const eng = @import("engine");
const StandardRenderer = @import("render.zig");
const Terrain = @import("terrain/terrain.zig");

pub const Descriptor = struct {
    health_points: ?i32 = null,
    anim_controller_desc: ?eng.animation.AnimController.Descriptor = null,
    particle_system_settings: ?eng.particles.ParticleSystemSettings = null,
    light: ?StandardRenderer.Light = null,
    terrain: ?Terrain.Descriptor = null,
};

health_points: ?i32,
anim_controller: ?eng.animation.AnimController,
particle_system: ?eng.particles.ParticleSystem,
light: ?StandardRenderer.Light,
terrain: ?Terrain,

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

pub fn init(desc: Descriptor) !Self {
    return Self {
        .health_points = desc.health_points,
        .anim_controller = if (desc.anim_controller_desc) |anim_desc| 
            try eng.animation.AnimController.init(general_alloc(), anim_desc) 
            else null,
        .particle_system = if (desc.particle_system_settings) |ps| 
            try eng.particles.ParticleSystem.init(general_alloc(), ps) 
            else null,
        .light = if (desc.light) |l| l else null,
        .terrain = if (desc.terrain) |t| 
            try Terrain.init(general_alloc(), t, .{}) 
            else null,
    };
}

inline fn general_alloc() std.mem.Allocator {
    return eng.get().general_allocator;
}

pub fn descriptor(self: *const Self, alloc: std.mem.Allocator) !Descriptor {
    const anim_desc = if (self.anim_controller) |ac| try ac.descriptor(alloc) else null;
    errdefer if (anim_desc) |ad| alloc.free(ad);

    const particle_system_settings = if (self.particle_system) |ps| ps.settings else null;

    const terrain_desc = if (self.terrain) |t| try t.descriptor(alloc) else null;
    errdefer if (terrain_desc) |td| alloc.free(td);

    return Descriptor {
        .health_points = self.health_points,
        .anim_controller_desc = anim_desc,
        .particle_system_settings = particle_system_settings,
        .light = self.light,
        .terrain = terrain_desc,
    };
}

