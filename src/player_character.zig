const std = @import("std");
const eng = @import("engine");
const entity_components = @import("entity.zig");
const zm = eng.zmath;
const KeyCode = eng.input.KeyCode;
const character_animation = @import("character_animation.zig");

pub const PlayerCharacterComponent = struct {
    const SelfComponent = @This();

    movement_speed: f32 = 4.0,

    pub fn deinit(self: *SelfComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !SelfComponent {
        _ = alloc;
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: SelfComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        _ = value;

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !SelfComponent {
        const component: SelfComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        _ = alloc;
        _ = object;

        return component;
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *SelfComponent, key: anytype) !void {
        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = entity;
            _ = component;
        }
    }
};

pub fn spawn_character(transform: eng.Transform) !eng.ecs.Entity {
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

    const new_character_entity = try eng.get().ecs.create_new_entity();
    errdefer eng.get().ecs.remove_entity(new_character_entity);

    {
        try eng.get().ecs.set_entity_name(new_character_entity, "character entity");

        const transform_component = try eng.get().ecs.add_component(eng.entity.TransformComponent, new_character_entity);
        transform_component.transform = transform;

        const model_component = try eng.get().ecs.add_component(eng.entity.ModelComponent, new_character_entity);
        model_component.model = try eng.assets.ModelAssetId.from_string_identifier("default|character");

        const anim_component = try eng.get().ecs.add_component(entity_components.AnimControllerComponent, new_character_entity);
        try character_animation.setup_character_anim_controller(&anim_component.anim_controller);

        const physics_component = try eng.get().ecs.add_component(eng.entity.PhysicsComponent, new_character_entity);
        physics_component.settings = .{ .CharacterVirtual = .{
            .settings = character_virtual_settings,
            .create_character = true,
            .extended_update_settings = .{},
        } };
        try physics_component.update_runtime_data(new_character_entity);

        const health_point_component = try eng.get().ecs.add_component(entity_components.HealthPointComponent, new_character_entity);
        health_point_component.health_points = 100;

        _ = try eng.get().ecs.add_component(PlayerCharacterComponent, new_character_entity);
    }

    return new_character_entity;
}

pub fn player_control_update() !void {
    const engine = eng.get();

    var camera_query = engine.ecs.query_iterator(.{ entity_components.CameraComponent, eng.entity.TransformComponent });
    const camera_component: *entity_components.CameraComponent,
    const camera_transform_component: *eng.entity.TransformComponent = camera_query.next() orelse return error.NoMainCamera;
    _ = camera_component;

    var query = engine.ecs.query_iterator(.{
        PlayerCharacterComponent,
        eng.entity.TransformComponent,
        eng.entity.PhysicsComponent,
        entity_components.AnimControllerComponent,
    });

    while (query.next()) |components| {
        const player_character_component: *PlayerCharacterComponent,
        const transform_component: *eng.entity.TransformComponent,
        const physics_component: *eng.entity.PhysicsComponent,
        const anim_controller_component: *entity_components.AnimControllerComponent = components;

        // Input to move the model around
        {
            var movement_direction = zm.f32x4s(0.0);
            if (!engine.imui.has_focus() and engine.input.get_key(KeyCode.W)) {
                movement_direction[2] += 1.0;
            }
            if (!engine.imui.has_focus() and engine.input.get_key(KeyCode.S)) {
                movement_direction[2] -= 1.0;
            }
            if (!engine.imui.has_focus() and engine.input.get_key(KeyCode.D)) {
                movement_direction[0] += 1.0;
            }
            if (!engine.imui.has_focus() and engine.input.get_key(KeyCode.A)) {
                movement_direction[0] -= 1.0;
            }

            if (!zm.all(movement_direction == zm.f32x4s(0.0), 3)) {
                movement_direction = zm.normalize3(movement_direction);
            }

            const is_running = (!engine.imui.has_focus() and engine.input.get_key(KeyCode.Shift));
            if (is_running) {
                movement_direction *= zm.f32x4s(2.0);
            }

            // Move slower walking backwards
            if (!is_running and movement_direction[2] < 0.0) {
                movement_direction[2] *= 0.8;
            }

            const camera_right = camera_transform_component.transform.right_direction(); // self.camera.transform.right_direction();
            const camera_forward_no_pitch = zm.cross3(zm.f32x4(0.0, 1.0, 0.0, 0.0), camera_right);

            var world_movement_direction = 
                camera_forward_no_pitch * zm.f32x4s(movement_direction[2])
                + camera_right * zm.f32x4s(movement_direction[0]);

            // engine.debug.draw_line(.{
            //     .p0 = character_entity.transform.position,
            //     .p1 = character_entity.transform.position + zm.normalize3(movement_direction),
            //     .colour = zm.f32x4(1.0, 0.0, 0.0, 1.0),
            // });

            // disable movement when attacking
            if (anim_controller_component.anim_controller.active_node == 2) {
                world_movement_direction = zm.f32x4s(0.0);
            }

            const character = physics_component.runtime_data.CharacterVirtual.virtual;

            var character_velocity = zm.loadArr3(character.getLinearVelocity());

            if (character_is_supported(character)) {
                // remove any gravity
                character_velocity[1] = 0.0;

                // apply supported movement
                if (zm.length3(world_movement_direction)[0] > 0.0) {
                    character_velocity = zm.lerp(character_velocity, world_movement_direction * zm.f32x4s(player_character_component.movement_speed), 0.5);
                } else {
                    // apply friction TODO FIX
                    character_velocity = zm.lerp(character_velocity, zm.f32x4s(0.0), 0.5);
                }
            } else {
                // if not supported then apply gravity
                character_velocity = character_velocity
                    + zm.loadArr3(engine.physics.zphy.getGravity()) * zm.f32x4s(eng.physics.PhysicsSystem.UpdateRateS * eng.physics.PhysicsSystem.UpdateRateS);
            }

            character.setLinearVelocity(zm.vecToArr3(character_velocity));

            // Rotate character model to match the input desired direction
            // If no input desired direction (normalized to nan) then remain in last rotation
            const rotate_towards_dir = if (!is_running) blk: {
                break :blk zm.normalize3(camera_forward_no_pitch + world_movement_direction);
            } else blk: {
                break :blk zm.normalize3(world_movement_direction);
            };

            if (!std.math.isNan(rotate_towards_dir[0])) {
                const rot = zm.lookAtRh(
                    zm.f32x4s(0.0),
                    rotate_towards_dir * zm.f32x4(1.0, 1.0, -1.0, 0.0),
                    zm.f32x4(0.0, 1.0, 0.0, 0.0)
                );
                transform_component.transform.rotation = zm.slerp(transform_component.transform.rotation, zm.matToQuat(rot), 0.1);
                // character.setRotation(
                //     zm.slerp(transform_component.transform.rotation, zm.matToQuat(rot), 0.1)
                // );
            }

            if (!engine.imui.has_focus() and engine.input.get_key_down(KeyCode.MouseLeft)) {
                var collector = eng.physics.util.CollideShapeCollector.init(engine.frame_allocator) catch |err| {
                    std.log.warn("Unable to create physics collector: {}", .{err});
                    unreachable;
                };
                defer collector.deinit();

                const box_shape_settings = eng.physics.zphy.BoxShapeSettings.create([3]f32{0.5, 0.5, 0.5}) catch unreachable;
                defer box_shape_settings.asShapeSettings().release();

                const box_shape = box_shape_settings.asShapeSettings().createShape() catch unreachable;
                defer box_shape.release();

                var camera_forward_2d = camera_transform_component.transform.forward_direction();
                camera_forward_2d[1] = 0.0;
                camera_forward_2d = zm.normalize3(camera_forward_2d);

                const shape_position = transform_component.transform.position + zm.f32x4(0.0, 0.6, 0.0, 0.0) + (camera_forward_2d);

                const matrix = zm.matToArr((eng.Transform {
                    .position = shape_position
                }).generate_model_matrix());

                anim_controller_component.anim_controller.trigger_event("character attack");

                // particles!
                // @TODO: FIX
                //self.player_attack_particle_system.settings.spawn_origin = shape_position;
                //self.player_attack_particle_system.settings.spawn_offset = camera_right;
                //self.player_attack_particle_system.settings.initial_velocity = zm.f32x4s(0.0); //camera_forward_2d * zm.f32x4s(10.0);
                //self.player_attack_particle_system.emit_particle_burst();

                engine.physics.zphy.getNarrowPhaseQuery().collideShape(
                    box_shape,
                    [3]f32{1.0, 1.0, 1.0},
                    matrix,
                    [3]eng.physics.zphy.Real{0.0, 0.0, 0.0},
                    @ptrCast(&collector),
                    .{}
                );

                std.log.info("hits: {}", .{collector.hits.items.len});
                for (collector.hits.items) |hit| {
                    var read_lock = engine.physics.init_body_read_lock(hit.body2_id) catch unreachable;
                    defer read_lock.deinit();

                    const user_data = eng.physics.PhysicsSystem.extract_entity_from_user_data(read_lock.body.getUserData());

                    hitblk: {
                        const hit_entity = eng.ecs.Entity{.idx = user_data.entity };
                        const hit_entity_name = eng.get().ecs.get_entity_name(hit_entity) orelse "unnamed";
                        std.log.info("- {s}", .{ hit_entity_name });

                        const healthpoint_component = eng.get().ecs.get_component(entity_components.HealthPointComponent, hit_entity) orelse break :hitblk;
                        healthpoint_component.health_points -= 10;

                        if (healthpoint_component.health_points <= 0) {
                            std.log.info("'{s}' fainted!", .{ hit_entity_name });
                        }
                    }
                }
            }

            // Update character animation parameters
            anim_controller_component.anim_controller.set_variable("character speed", zm.length3(character_velocity)[0]);
            anim_controller_component.anim_controller.set_variable("character walk speed norm", std.math.clamp(zm.length3(character_velocity)[0] / 4.0, 0.0, 1.0));
        }
    }
}

fn character_is_supported(chr: *eng.physics.zphy.CharacterVirtual) bool {
    return chr.getGroundState() == eng.physics.zphy.CharacterGroundState.on_ground;
}
