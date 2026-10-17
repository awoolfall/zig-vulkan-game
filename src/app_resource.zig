const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;

const StandardRenderer = @import("render.zig");
const TerrainRenderer = @import("terrain/terrain_renderer.zig");
const Ocean = @import("ocean/ocean.zig");
const Clouds = @import("clouds/clouds.zig");
const Atmosphere = @import("atmosphere/atmosphere.zig");
const EditMode = @import("edit_mode.zig");

pub const RESOURCE_NAME = "App";

const Self = @This();

character_entity: ?eng.ecs.Entity = null,
character_animation_graph: eng.AnimationGraph,

player_attack_particle_system: eng.ParticleSystem,

standard_renderer: StandardRenderer,
terrain_renderer: TerrainRenderer,
ocean: Ocean,
clouds: Clouds,
atmosphere: Atmosphere,
particles_renderer: eng.ParticleRenderer,

edit_mode: EditMode,
current_mode: enum { Edit, Play } = .Edit,
state: ?struct {
    arena: std.heap.ArenaAllocator,
    entities: []const EditMode.SerializedEntity,
} = null,

command_pool: eng.gfx.CommandPool.Ref,
command_buffers: [4]eng.gfx.CommandBuffer,

uber_cmd_semaphores: []eng.gfx.Semaphore,

pub fn deinit(self: *Self) void {
    if (self.state) |state| {
        state.arena.deinit();
    }

    self.player_attack_particle_system.deinit();

    for (self.uber_cmd_semaphores) |s| {
        s.deinit();
    }
    eng.get().general_allocator.free(self.uber_cmd_semaphores);

    self.standard_renderer.deinit();
    self.terrain_renderer.deinit();
    self.ocean.deinit();
    self.clouds.deinit();
    self.atmosphere.deinit();
    self.particles_renderer.deinit();
    self.edit_mode.deinit();

    for (self.command_buffers[0..]) |c| { c.deinit(); }
    self.command_pool.deinit();

    self.character_animation_graph.deinit();
}

pub fn init() !Self {
    var player_attack_particle_system_settings = eng.ParticleSystem.ParticleSystemSettings {
            .max_particles = 300,
            .alignment = .{ .VelocityAligned = 5.0 },
            .shape = .Circle,
            .spawn_origin = zm.f32x4(0.0, 0.0, 0.0, 0.0),
            .spawn_offset = zm.f32x4s(0.0),
            .spawn_radius = 1.0,
            .spawn_rate = 0.0,
            .spawn_rate_variance = 0.0,
            .burst_count = 60,
            .particle_lifetime = 1.0,
    };
    defer player_attack_particle_system_settings.deinit(eng.get().general_allocator);

    try player_attack_particle_system_settings.scale.appendSlice(eng.get().general_allocator, &.{
        .{ .value = zm.f32x4s(0.05), },
    });
    try player_attack_particle_system_settings.colour.appendSlice(eng.get().general_allocator, &.{
        .{ .value = zm.srgbToRgb(zm.f32x4(0.0, 0.0, 0.0, 1.0)), .key_time = 0.0, },
        .{ .value = zm.srgbToRgb(zm.f32x4(0.0, 0.0, 0.0, 0.0)), .key_time = 1.0, .easing_into = .OutLinear },
        // .{ .value = zm.hsvToRgb(zm.f32x4(0.0, 1.0, 1.0, 1.0)), .key_time = 0.0, },
        // .{ .value = zm.hsvToRgb(zm.f32x4(0.5, 1.0, 1.0, 1.0)), .key_time = 0.5, },
        // .{ .value = zm.hsvToRgb(zm.f32x4(0.999, 1.0, 1.0, 1.0)), .key_time = 1.0, },
    });
    try player_attack_particle_system_settings.forces.appendSlice(eng.get().general_allocator, &.{
        .{ .Vortex = .{ .axis = zm.f32x4(0.0, 1.0, 0.0, 0.0), .force = 50.0, .origin_pull = 50.0, } },
        .{ .Drag = 5.0 },
    });

    var player_attack_particle_system = try eng.ParticleSystem.init(eng.get().general_allocator, player_attack_particle_system_settings);
    errdefer player_attack_particle_system.deinit();

    var character_animation_graph = try @import("character_animation.zig").character_animation_graph();
    errdefer character_animation_graph.deinit();

    var command_pool = try eng.gfx.CommandPool.init(.{
        .allow_reset_command_buffers = true,
        .queue_family = .Graphics,
    });
    errdefer command_pool.deinit();

    const command_buffers: [4]eng.gfx.CommandBuffer = 
        (command_pool.get() catch unreachable).allocate_command_buffers(.{}, 4) catch unreachable;

    const uber_cmd_semaphores = try eng.get().general_allocator.alloc(eng.gfx.Semaphore, eng.gfx.GfxState.get().frames_in_flight());
    errdefer eng.get().general_allocator.free(uber_cmd_semaphores);

    var uber_cmd_semaphores_list = std.ArrayList(eng.gfx.Semaphore).initBuffer(uber_cmd_semaphores);
    errdefer for (uber_cmd_semaphores_list.items) |s| { s.deinit(); };

    for (0..eng.gfx.GfxState.get().frames_in_flight()) |_| {
        try uber_cmd_semaphores_list.appendBounded(try eng.gfx.Semaphore.init(.{}));
    }

    var standard_renderer = try StandardRenderer.init();
    errdefer standard_renderer.deinit();

    var terrain_renderer = try TerrainRenderer.init();
    errdefer terrain_renderer.deinit();

    var atmosphere = try Atmosphere.init(.{});
    errdefer atmosphere.deinit();

    var ocean = try Ocean.init(.{ .amplitude = 0.08, .wind = .{ 9.0, 0.0 } }, atmosphere.cubemap_sampler_view);
    errdefer ocean.deinit();

    var clouds = try Clouds.init(eng.get().general_allocator);
    errdefer clouds.deinit();

    var particles_renderer = try eng.ParticleRenderer.init(eng.get().general_allocator);
    errdefer particles_renderer.deinit();

    var edit_mode = try EditMode.init(&standard_renderer);
    errdefer edit_mode.deinit();

    return Self {
        .character_animation_graph = character_animation_graph,

        .player_attack_particle_system = player_attack_particle_system,

        .standard_renderer = standard_renderer,
        .terrain_renderer = terrain_renderer,
        .ocean = ocean,
        .clouds = clouds,
        .atmosphere = atmosphere,
        .particles_renderer = particles_renderer,
        .edit_mode = edit_mode,

        .command_pool = command_pool,
        .command_buffers = command_buffers,

        .uber_cmd_semaphores = uber_cmd_semaphores,
    };
}