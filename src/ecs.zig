pub const HealthPointComponent = @import("ecs/health_point_component.zig");
pub const AnimControllerComponent = @import("ecs/animation_controller_component.zig");
pub const ParticleSystemComponent = @import("ecs/particle_system_component.zig");
pub const LightComponent = @import("ecs/light_component.zig");
pub const TerrainComponent = @import("ecs/terrain_component.zig");
pub const CloudVolumeComponent = @import("ecs/cloud_volume_component.zig");
pub const CameraComponent = @import("ecs/camera_component.zig");
pub const PlayerCharacterComponent = @import("ecs/player_character_component.zig");
pub const OpponentCharacterComponent = @import("ecs/opponent_character_component.zig");

pub const EntityComponents = .{
    HealthPointComponent,
    AnimControllerComponent,
    ParticleSystemComponent,
    LightComponent,
    TerrainComponent,
    CloudVolumeComponent,
    CameraComponent,
    PlayerCharacterComponent,
    OpponentCharacterComponent,
};
