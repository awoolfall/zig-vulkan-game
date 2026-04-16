const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const ecs = @import("ecs.zig");
const character_animation = @import("character_animation.zig");

pub fn spawn_opponent_character(transform: eng.Transform) !eng.ecs.Entity {
    const chara_shape = eng.physics.ShapeSettings {
        .shape = .{ .Capsule = .{
            .half_height = 0.7,
            .radius = 0.2,
        } },
        .offset_transform = eng.Transform {
            .position = zm.f32x4(0.0, 0.7 + 0.2, 0.0, 0.0),
            .rotation = zm.qidentity(),
        },
    };

    const character_virtual_settings = eng.physics.CharacterVirtualSettings {
        .base = eng.physics.CharacterBaseSettings {
            .up = [4]f32{0.0, 1.0, 0.0, 0.0},
            .max_slope_angle = 70.0,
            .shape = chara_shape,
        },
        .mass = 70.0,
        .character_padding = 0.02,
    };

    const new_entity = try eng.get().ecs.create_new_entity();
    errdefer eng.get().ecs.remove_entity(new_entity);

    try eng.get().ecs.set_entity_name(new_entity, "opponent entity");

    _ = try eng.get().ecs.add_component(ecs.OpponentCharacterComponent, new_entity);

    const transform_component = try eng.get().ecs.add_component(eng.ecs.TransformComponent, new_entity);
    transform_component.transform = transform;

    const model_component = try eng.get().ecs.add_component(eng.ecs.ModelComponent, new_entity);
    model_component.model = try eng.assets.ModelAssetId.from_string_identifier("default|character");

    const anim_component = try eng.get().ecs.add_component(ecs.AnimControllerComponent, new_entity);
    try character_animation.setup_character_anim_controller(&anim_component.anim_controller);

    const physics_component = try eng.get().ecs.add_component(eng.ecs.PhysicsComponent, new_entity);
    physics_component.settings = .{ .CharacterVirtual = .{
        .settings = character_virtual_settings,
        .create_character = true,
        .extended_update_settings = .{},
    } };
    try physics_component.update_runtime_data(new_entity);

    const health_points_component = try eng.get().ecs.add_component(ecs.HealthPointComponent, new_entity);
    health_points_component.health_points = 100;

    return new_entity;
}

pub fn opponent_behaviour_system() !void {
    var player_query = eng.get().ecs.query_iterator(.{ ecs.PlayerCharacterComponent, eng.ecs.TransformComponent });
    const player_character_component: *ecs.PlayerCharacterComponent,
    const player_transform_component: *eng.ecs.TransformComponent = player_query.next() orelse return error.UnableToFindPlayerCharacter;
    _ = player_character_component;

    var query = eng.get().ecs.query_iterator(.{ ecs.OpponentCharacterComponent, eng.ecs.TransformComponent, eng.ecs.PhysicsComponent });
    while (query.next()) |components| {
        const opponent_component: *ecs.OpponentCharacterComponent,
        const transform_component: *eng.ecs.TransformComponent,
        const physics_component: *eng.ecs.PhysicsComponent = components;

        var desired_movement_direction = zm.f32x4s(0.0);

        const pos_diff = player_transform_component.transform.position - transform_component.transform.position;
        const desired_distance = 5.0;
        if (zm.length3(pos_diff)[0] > desired_distance) {
            desired_movement_direction += zm.normalize3(pos_diff);
        }

        const opponent_physics = physics_component.runtime_data.CharacterVirtual.virtual;

        if (zm.length3(desired_movement_direction)[0] != 0.0) {
            desired_movement_direction = zm.normalize3(desired_movement_direction);

            var character_velocity = zm.loadArr3(opponent_physics.getLinearVelocity());

            if (character_is_supported(opponent_physics)) {
                // remove any gravity
                character_velocity[1] = 0.0;

                const friction = 8.0;

                character_velocity = character_velocity
                    // apply supported movement
                    + desired_movement_direction * zm.f32x4s(opponent_component.movement_speed * friction * eng.get().time.delta_time_f32())
                    // apply friction
                    - character_velocity * zm.f32x4s(friction * eng.get().time.delta_time_f32());
            } else {
                // if not supported then apply gravity
                character_velocity = character_velocity
                    + zm.loadArr3(eng.get().physics.zphy.getGravity()) * zm.f32x4s(eng.get().time.delta_time_f32());
            }

            opponent_physics.setLinearVelocity(zm.vecToArr3(character_velocity));
        } else {
            opponent_physics.setLinearVelocity(.{ 0.0, 0.0, 0.0 });
        }

        // Rotate to face character
        const rot = zm.lookAtRh(zm.f32x4s(0.0), zm.normalize3(pos_diff), zm.f32x4(0.0, 1.0, 0.0, 0.0));
        transform_component.transform.rotation = zm.slerp(transform_component.transform.rotation, zm.matToQuat(rot), 0.1);
        // opponent_physics.setRotation(
        //     zm.slerp(opponent.transform.rotation, zm.matToQuat(rot), 0.1)
        // );
    }
}

fn character_is_supported(chr: *eng.physics.zphy.CharacterVirtual) bool {
    return chr.getGroundState() == eng.physics.zphy.CharacterGroundState.on_ground;
}