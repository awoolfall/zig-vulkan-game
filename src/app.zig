const Self = @This();

const std = @import("std");

const eng = @import("engine");
const zphy = eng.physics.zphy;
const zm = eng.zmath;
const Transform = eng.Transform;
const gfx = eng.gfx;
const Imui = eng.ui;
const window = eng.window;
const KeyCode = eng.input.KeyCode;
const gen = eng.gen;
const ph = eng.physics;
const es = eng.easings;
const anim = eng.animation;
const assets = eng.assets;
const sr = eng.serialize;
const FontEnum = eng.ui.FontEnum;

const TerrainRenderer = @import("terrain/terrain_renderer.zig");
const StandardRenderer = @import("render.zig");
const EditMode = @import("edit_mode.zig");

const gitrev = eng.gitrev;
const gitchanged = eng.gitchanged;

pub const EntityData = @import("entity.zig");

camera: eng.camera.Camera,
target_old_pos: zm.F32x4 = zm.f32x4s(0.0),

character_idx: gen.GenerationalIndex,
opponent_idx: gen.GenerationalIndex,

app_life_asset_pack_id: assets.AssetPackId,

player_attack_particle_system: eng.particles.ParticleSystem,

standard_renderer: StandardRenderer,
terrain_renderer: TerrainRenderer,
particles_renderer: eng.particles_renderer.ParticleRenderer,

edit_mode: EditMode,
current_mode: enum { Edit, Play } = .Edit,

command_pool: gfx.CommandPool.Ref,
command_buffers: [4]gfx.CommandBuffer,

uber_cmd_semaphores: []gfx.Semaphore,

pub fn deinit(self: *Self) void {
    std.log.info("App deinit!", .{});

    self.player_attack_particle_system.deinit();

    eng.get().asset_manager.unload_asset_pack(self.app_life_asset_pack_id)
        catch unreachable;

    for (self.uber_cmd_semaphores) |s| {
        s.deinit();
    }
    eng.get().general_allocator.free(self.uber_cmd_semaphores);

    self.standard_renderer.deinit();
    self.terrain_renderer.deinit();
    self.particles_renderer.deinit();
    self.edit_mode.deinit();

    for (self.command_buffers[0..]) |c| { c.deinit(); }
    self.command_pool.deinit();
}

pub fn init() !Self {
    std.log.info("App init!", .{});
    const engine = eng.get();

    var asset_pack = try assets.AssetPack.init_from_file(engine.general_allocator, "default", "default_asset_pack.zon");
    errdefer asset_pack.deinit();

    const asset_pack_id = try engine.asset_manager.add_asset_pack(asset_pack);
    try engine.asset_manager.load_asset_pack(asset_pack_id);

    // asset_pack.save_to_file(engine.general_allocator, "zig-out") catch |err| {
    //     std.log.err("Unable to save asset pack: {}", .{ err });
    // };
    
    // Print model animation names
    //
    // const character_model_id = engine.asset_manager.find_asset_id(assets.ModelAsset, "default|character").?;
    // const character_model = engine.asset_manager.get_asset(assets.ModelAsset, character_model_id) catch unreachable;
    // std.log.info("character model animations:", .{});
    // for (character_model.animations, 0..) |*animation, i| {
    //     std.log.info("{}. anim: {s}", .{i, animation.name});
    // }

    // for (0..100) |_| {
    //     chara_transform.position += zm.f32x4(0.0, 0.5, 0.0, 0.0);
    //     _ = try engine.entities.new_entity(Engine.EntityDescriptor {
    //         .name = "opponent entity",
    //         .should_serialize = true,
    //         .model = "default|character",
    //         .transform = chara_transform,
    //         .physics = .{ .Character = .{
    //             .settings = character_settings,
    //         } },
    //         .app = .{
    //             .health_points = 100,
    //             .anim_controller_desc = anim_desc,
    //         },
    //         });
    // }

    engine.physics.zphy.optimizeBroadPhase();

    var player_attack_particle_system_settings = eng.particles.ParticleSystemSettings {
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

    var player_attack_particle_system = try eng.particles.ParticleSystem.init(engine.general_allocator, player_attack_particle_system_settings);
    errdefer player_attack_particle_system.deinit();

    var command_pool = try gfx.CommandPool.init(.{
        .allow_reset_command_buffers = true,
        .queue_family = .Graphics,
    });
    errdefer command_pool.deinit();

    const command_buffers: [4]gfx.CommandBuffer = 
        (command_pool.get() catch unreachable).allocate_command_buffers(.{}, 4) catch unreachable;

    const uber_cmd_semaphores = try eng.get().general_allocator.alloc(gfx.Semaphore, gfx.GfxState.get().frames_in_flight());
    errdefer eng.get().general_allocator.free(uber_cmd_semaphores);

    var uber_cmd_semaphores_list = std.ArrayList(gfx.Semaphore).initBuffer(uber_cmd_semaphores);
    errdefer for (uber_cmd_semaphores_list.items) |s| { s.deinit(); };

    for (0..gfx.GfxState.get().frames_in_flight()) |_| {
        try uber_cmd_semaphores_list.appendBounded(try gfx.Semaphore.init(.{}));
    }

    return Self {
        .camera = eng.camera.Camera {
            .field_of_view_y = eng.camera.Camera.horizontal_to_vertical_fov(std.math.degreesToRadians(90.0), engine.gfx.swapchain_aspect()),
            .near_field = 0.3,
            .far_field = 1000.0,
            .move_speed = 10.0,
            .mouse_sensitivity = 0.001,
            .max_orbit_distance = 10.0,
            .min_orbit_distance = 1.0,
            .orbit_distance = 5.0,
        },

        .character_idx = gen.GenerationalIndex.invalid(),
        .opponent_idx = gen.GenerationalIndex.invalid(),

        .app_life_asset_pack_id = asset_pack_id,

        .player_attack_particle_system = player_attack_particle_system,

        .standard_renderer = try StandardRenderer.init(),
        .terrain_renderer = try TerrainRenderer.init(),
        .particles_renderer = try eng.particles_renderer.ParticleRenderer.init(engine.general_allocator),
        .edit_mode = try EditMode.init(),

        .command_pool = command_pool,
        .command_buffers = command_buffers,

        .uber_cmd_semaphores = uber_cmd_semaphores,
    };
}

fn update(self: *Self) !void {
    const engine = eng.get();

    // switch modes
    if (!engine.imui.has_focus() and engine.input.get_key_down(KeyCode.F1)) {
        switch (self.current_mode) {
            .Edit => {
                self.current_mode = .Play;
                engine.time.time_scale = 1.0;
            },
            .Play => {
                self.current_mode = .Edit;
                self.edit_mode.editor_camera.transform = self.camera.transform;
                engine.time.time_scale = 0.01;
            },
        }
    }

    // update particle systems
    var entities = engine.entities.list.iterator();
    while (entities.next()) |entity| {
        if (entity.app.particle_system) |*ps| {
            ps.settings.spawn_origin = entity.transform.position;
            ps.update(&engine.time);
        }
    }

    self.player_attack_particle_system.update(&engine.time);

    // update
    var render_camera: *eng.camera.Camera = undefined;
    switch (self.current_mode) {
        .Edit => {
            self.edit_mode.update(&self.standard_renderer.selection_textures, &self.terrain_renderer) catch |err| {
                std.log.err("Edit mode update failed: {}", .{err});
            };
            render_camera = &self.edit_mode.editor_camera;

            if (self.edit_mode.render_only_selected_entity) blk: {
                if (self.edit_mode.selected_entity) |si| {
                    const selected_entity = eng.get().entities.get(si) orelse break :blk;
                    try self.push_entity_for_rendering(eng.get().frame_allocator, selected_entity, si.index);
                }
            } else {
                try self.push_all_entities_for_rendering();
            }
        },
        .Play => {
            blk: {
                if (self.character_idx.is_invalid()) {
                    // spawn character
                    const character_spawner_idx = engine.entities.find_entity_by_name("character-spawner") orelse break :blk;
                    const character_spawner = engine.entities.get(character_spawner_idx).?;
                    const character_spawner_transform = character_spawner.transform;

                    const chara_shape = ph.ShapeSettings {
                        .shape = .{ .Capsule = .{
                            .half_height = 0.7,
                            .radius = 0.2,
                        } },
                        .offset_transform = Transform {
                            .position = zm.f32x4(0.0, 0.7 + 0.2, 0.0, 0.0),
                            .rotation = zm.qidentity(),
                        },
                    };

                    const character_virtual_settings = ph.CharacterVirtualSettings {
                        .base = ph.CharacterBaseSettings {
                            .up = [4]f32{0.0, 1.0, 0.0, 0.0},
                            .max_slope_angle = 70.0,
                            .shape = chara_shape,
                        },
                        .mass = 70.0,
                        .character_padding = 0.02,
                    };

                    self.character_idx = try engine.entities.new_entity(eng.Engine.EntityDescriptor {
                        .name = "character entity",
                        .should_serialize = false,
                        .model = "default|character",
                        .transform = Transform {
                            .position = character_spawner_transform.position,
                            .rotation = character_spawner_transform.rotation,
                        },
                        .physics = .{ .CharacterVirtual = .{
                            .settings = character_virtual_settings,
                            .create_character = true,
                            .extended_update_settings = .{},
                        } },
                        .app = .{
                            .health_points = 100,
                            .anim_controller_desc = character_anim_description(),
                        },
                    });
                }
            }

            blk: {
                if (self.opponent_idx.is_invalid()) {
                    // spawn character
                    const spawner_idx = engine.entities.find_entity_by_name("opponent-spawner") orelse break :blk;
                    const spawner = engine.entities.get(spawner_idx).?;
                    const spawner_transform = spawner.transform;

                    const chara_shape = ph.ShapeSettings {
                        .shape = .{ .Capsule = .{
                            .half_height = 0.7,
                            .radius = 0.2,
                        } },
                        .offset_transform = Transform {
                            .position = zm.f32x4(0.0, 0.7 + 0.2, 0.0, 0.0),
                            .rotation = zm.qidentity(),
                        },
                    };

                    const character_virtual_settings = ph.CharacterVirtualSettings {
                        .base = ph.CharacterBaseSettings {
                            .up = [4]f32{0.0, 1.0, 0.0, 0.0},
                            .max_slope_angle = 70.0,
                            .shape = chara_shape,
                        },
                        .mass = 70.0,
                        .character_padding = 0.02,
                    };

                    self.opponent_idx = try engine.entities.new_entity(eng.Engine.EntityDescriptor {
                        .name = "opponent entity",
                        .should_serialize = false,
                        .model = "default|character",
                        .transform = Transform {
                            .position = spawner_transform.position,
                            .rotation = spawner_transform.rotation,
                        },
                        .physics = .{ .CharacterVirtual = .{
                            .settings = character_virtual_settings,
                            .create_character = true,
                            .extended_update_settings = .{},
                        } },
                        .app = .{
                            .health_points = 100,
                            .anim_controller_desc = character_anim_description(),
                        },
                    });
                }
            }

            // Input to move the model around
            if (engine.entities.get(self.character_idx)) |character_entity| {
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

                const camera_right = self.camera.transform.right_direction();
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
                if (character_entity.app.anim_controller) |*ac| {
                    if (ac.active_node == 2) {
                        world_movement_direction = zm.f32x4s(0.0);
                    }
                }

                const character = character_entity.physics.?.CharacterVirtual.virtual;
                var character_velocity = zm.loadArr3(character.getLinearVelocity());

                if (character_is_supported(character)) {
                    // remove any gravity
                    character_velocity[1] = 0.0;

                    const character_movement_speed = 4.0;
                    const friction = 8.0;

                    character_velocity = character_velocity
                        // apply supported movement
                        + world_movement_direction * zm.f32x4s(character_movement_speed * friction * engine.time.delta_time_f32())
                        // apply friction
                        - character_velocity * zm.f32x4s(friction * engine.time.delta_time_f32());
                } else {
                    // if not supported then apply gravity
                    character_velocity = character_velocity
                        + zm.loadArr3(engine.physics.zphy.getGravity()) * zm.f32x4s(eng.get().time.delta_time_f32());
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
                    character.setRotation(
                        zm.slerp(character_entity.transform.rotation, zm.matToQuat(rot), 0.1)
                    );
                }

                if (!engine.imui.has_focus() and engine.input.get_key_down(KeyCode.MouseLeft)) {
                    var collector = eng.physics.util.CollideShapeCollector.init(engine.frame_allocator) catch |err| {
                        std.log.warn("Unable to create physics collector: {}", .{err});
                        unreachable;
                    };
                    defer collector.deinit();

                    const box_shape_settings = zphy.BoxShapeSettings.create([3]f32{0.5, 0.5, 0.5}) catch unreachable;
                    defer box_shape_settings.asShapeSettings().release();

                    const box_shape = box_shape_settings.asShapeSettings().createShape() catch unreachable;
                    defer box_shape.release();

                    var camera_forward_2d = self.camera.transform.forward_direction();
                    camera_forward_2d[1] = 0.0;
                    camera_forward_2d = zm.normalize3(camera_forward_2d);

                    const shape_position = character_entity.transform.position + zm.f32x4(0.0, 0.6, 0.0, 0.0) + (camera_forward_2d);

                    const matrix = zm.matToArr((Transform {
                        .position = shape_position
                    }).generate_model_matrix());

                    if (character_entity.app.anim_controller) |*ac| {
                        ac.trigger_event("character attack");
                    }

                    // particles!
                    self.player_attack_particle_system.settings.spawn_origin = shape_position;
                    self.player_attack_particle_system.settings.spawn_offset = camera_right;
                    self.player_attack_particle_system.settings.initial_velocity = zm.f32x4s(0.0); //camera_forward_2d * zm.f32x4s(10.0);
                    self.player_attack_particle_system.emit_particle_burst();

                    engine.physics.zphy.getNarrowPhaseQuery().collideShape(
                        box_shape,
                        [3]f32{1.0, 1.0, 1.0},
                        matrix,
                        [3]zphy.Real{0.0, 0.0, 0.0},
                        @ptrCast(&collector),
                        .{}
                    );

                    std.log.info("hits: {}", .{collector.hits.items.len});
                    for (collector.hits.items) |hit| {
                        var read_lock = engine.physics.init_body_read_lock(hit.body2_id) catch unreachable;
                        defer read_lock.deinit();

                        const user_data = ph.PhysicsSystem.extract_entity_from_user_data(read_lock.body.getUserData());
                        if (engine.entities.get(user_data.entity)) |entity| {
                            std.log.info("- {s}", .{entity.name orelse "unnamed"});

                            if (entity.app.health_points) |*hp| {
                                hp.* -= 10;
                                if (hp.* < 0) {
                                    std.log.info("'{s}' fainted!", .{entity.name orelse "unnamed"});
                                }
                            }
                        } else { std.log.warn("Failed to get entity!", .{}); }
                    }
                }

                // Update character animation parameters
                if (character_entity.app.anim_controller) |*ac| {
                    ac.set_variable("character speed", zm.length3(character_velocity)[0]);
                    ac.set_variable("character walk speed norm", std.math.clamp(zm.length3(character_velocity)[0] / 4.0, 0.0, 1.0));
                }
            }

            var vel_buf: [128]u8 = [_]u8{0} ** 128;
            var vel_text: []u8 = vel_buf[0..0];
            if (engine.entities.get(self.character_idx)) |character_entity| {
                const character = character_entity.physics.?.CharacterVirtual.virtual;
                const character_velocity = zm.loadArr3(character.getLinearVelocity());
                vel_text = std.fmt.bufPrint(vel_buf[0..], "character speed: {d:.2}\nvelocity: {d:.2}\nis supported: {}", .{
                    zm.length3(character_velocity)[0],
                    character_velocity,
                    character_is_supported(character_entity.physics.?.CharacterVirtual.virtual),
                }) catch unreachable;

                {
                    _ = engine.imui.push_floating_layout(.Y, 100, 500, .{@src()});
                    const l = Imui.widgets.label.create(&eng.get().imui, vel_text);
                    if (engine.imui.get_widget(l.id)) |tw| {
                        tw.text_content.?.font = .GeistMono;
                        tw.text_content.?.size = 15;
                        tw.text_content.?.colour = eng.get().imui.palette().text_dark;
                    }
                    _ = engine.imui.pop_layout();
                }
            }

            blk: {
                const opponent = engine.entities.get(self.opponent_idx) orelse break :blk;
                const character = engine.entities.get(self.character_idx) orelse break :blk;

                var desired_movement_direction = zm.f32x4s(0.0);

                const pos_diff = character.transform.position - opponent.transform.position;
                const desired_distance = 5.0;
                if (zm.length3(pos_diff)[0] > desired_distance) {
                    desired_movement_direction += zm.normalize3(pos_diff);
                }

                const character_physics = opponent.physics.?.CharacterVirtual.virtual;

                if (zm.length3(desired_movement_direction)[0] != 0.0) {
                    desired_movement_direction = zm.normalize3(desired_movement_direction);

                    var character_velocity = zm.loadArr3(character_physics.getLinearVelocity());

                    if (character_is_supported(character_physics)) {
                        // remove any gravity
                        character_velocity[1] = 0.0;

                        const character_movement_speed = 4.0;
                        const friction = 8.0;

                        character_velocity = character_velocity
                            // apply supported movement
                            + desired_movement_direction * zm.f32x4s(character_movement_speed * friction * engine.time.delta_time_f32())
                            // apply friction
                            - character_velocity * zm.f32x4s(friction * engine.time.delta_time_f32());
                    } else {
                        // if not supported then apply gravity
                        character_velocity = character_velocity
                            + zm.loadArr3(engine.physics.zphy.getGravity()) * zm.f32x4s(eng.get().time.delta_time_f32());
                    }

                    character_physics.setLinearVelocity(zm.vecToArr3(character_velocity));
                } else {
                    character_physics.setLinearVelocity(zm.vecToArr3(zm.f32x4s(0.0)));
                }

                // Rotate to face character
                const rot = zm.lookAtRh(zm.f32x4s(0.0), zm.normalize3(pos_diff), zm.f32x4(0.0, 1.0, 0.0, 0.0));
                character_physics.setRotation(
                    zm.slerp(opponent.transform.rotation, zm.matToQuat(rot), 0.1)
                );
            }

            // // Cast ray from camera
            // if (engine.entities.get(self.camera_idx)) |camera_entity| {
            //     var raycast_result = engine.physics.zphy.getNarrowPhaseQuery().castRay(.{
            //         .origin = camera_entity.transform.position,
            //         .direction = camera_entity.transform.forward_direction(),
            //     }, .{});
            //     if (raycast_result.has_hit) {
            //         std.log.info("  raycast hit! id:{}", .{raycast_result.hit.body_id});
            //     }
            // }

            var target_pos = zm.f32x4s(0.0);
            if (engine.entities.get(self.character_idx)) |character_entity| {
                target_pos = character_entity.transform.position + zm.f32x4(0.0, 1.5, 0.0, 0.0);
            }

            // update camera
            self.camera.orbit_camera_update(target_pos, &engine.window, &engine.input, &engine.time);

            render_camera = &self.camera;

            try self.push_all_entities_for_rendering();
        },
    }

    var fps_buf: [128]u8 = [_]u8{0} ** 128;
    const fps_text = std.fmt.bufPrint(fps_buf[0..], "fps: {d:0.1}\nframe time: {d:2.3}ms\nwait time: {d:2.3}ms\nwait %: {d:0.0}", .{
        engine.time.get_fps(),
        (engine.time.delta_time_f32() - engine.time.last_frame_wait_time_s) * std.time.ms_per_s,
        engine.time.last_frame_wait_time_s * std.time.ms_per_s,
        (engine.time.last_frame_wait_time_s / engine.time.last_frame_time_s) * 100.0
    }) catch unreachable;

    {
        _ = engine.imui.push_floating_layout(
            .Y, 
            5.0, 
            25.0 + engine.imui.get_font(FontEnum.GeistMono).font_metrics.descender * 12.0, 
            .{@src()}
        );
        const l = Imui.widgets.label.create(&eng.get().imui, fps_text);
        if (engine.imui.get_widget(l.id)) |tw| {
            tw.text_content.?.font = .GeistMono;
            tw.text_content.?.size = 12;
            tw.text_content.?.colour = eng.get().imui.palette().text_dark;
        }
        _ = engine.imui.pop_layout();
    }

    var rev_buf: [64]u8 = [_]u8{0} ** 64;
    const rev_text = std.fmt.bufPrint(rev_buf[0..], "zig-dx11 - {x}{s}", .{
        gitrev,
        blk: { if (gitchanged) { break :blk "*"; } else { break :blk ""; } },
    }) catch unreachable;
    {
        _ = engine.imui.push_floating_layout(.Y, 10.0, @as(f32, @floatFromInt(engine.gfx.swapchain_size()[1])) - 
            engine.imui.get_font(FontEnum.GeistMono).font_metrics.line_height * 12.0, .{@src()});
        const l = Imui.widgets.label.create(&eng.get().imui, rev_text);
        if (engine.imui.get_widget(l.id)) |tw| {
            tw.text_content.?.font = .GeistMono;
            tw.text_content.?.size = 12;
            tw.text_content.?.colour = eng.get().imui.palette().text_dark;
        }
        _ = engine.imui.pop_layout();
    }


    // Draw frame
    const camera_view_matrix = render_camera.transform.generate_view_matrix();
    const camera_projection_matrix = render_camera.generate_perspective_matrix(engine.gfx.swapchain_aspect());

    const image_available_semaphore = engine.gfx.begin_frame() catch |err| {
        std.log.warn("Unable to begin frame: {}", .{err});
        return;
    };

    const frame_idx = eng.get().time.frame_number % 4;
    var cmd = &self.command_buffers[@intCast(frame_idx)];

    cmd.reset() catch |err| {
        std.log.warn("Unable to reset command buffer: {}", .{err});
        return;
    };
    cmd.cmd_begin(.{ .one_time_submit = true, }) catch |err| {
        std.log.warn("Unable to begin command buffer: {}", .{err});
        return;
    };

    // Render to HDR buffer
    // Standard HDR render
    self.standard_renderer.render_cmd(
        .{
            .camera = render_camera,
            .selected_entity_idx = if (self.edit_mode.selected_entity) |i| i.index else null,
        },
        cmd
    ) catch |err| {
        std.log.warn("Unable to render standard renderer: {}", .{err});
    };

    // render terrains
    var entity_iter = engine.entities.list.iterator();
    while (entity_iter.next()) |entity| {
        if (entity.app.terrain) |*terrain| {
            self.terrain_renderer.render(
                cmd,
                render_camera,
                terrain,
                entity.transform,
                &self.standard_renderer
            );
        }
    }
    self.standard_renderer.clear();

    self.particles_renderer.push_particle_system(&self.player_attack_particle_system) catch |err| {
        std.log.warn("Unable to push particle system '{s}' for rendering: {}", .{
            "player attack",
            err
        });
    };

    // render particle systems
    self.particles_renderer.render(cmd, render_camera) catch |err| {
        std.log.warn("Unable to render particle systems: {}", .{err});
    };
    self.particles_renderer.clear();

    // apply bloom
    engine.gfx.bloom_filter.render_bloom(cmd, .{}) catch |err| {
        std.log.warn("Unable to apply bloom filter: {}", .{err});
    };

    // Transition HDR image from colour output attachment to shader resource
    cmd.cmd_pipeline_barrier(gfx.CommandBuffer.PipelineBarrierInfo {
        .src_stage = .{ .color_attachment_output = true, },
        .dst_stage = .{ .fragment_shader = true, },
        .image_barriers = &.{
            gfx.CommandBuffer.ImageMemoryBarrierInfo {
                .image = gfx.GfxState.get().default.hdr_image,
                .old_layout = gfx.ImageLayout.ColorAttachmentOptimal,
                .new_layout = gfx.ImageLayout.ShaderReadOnlyOptimal,
                .src_access_mask = .{ .color_attachment_write = true, },
                .dst_access_mask = .{ .shader_read = true, },
            },
        },
    });

    // Tonemap HDR image onto LDR buffer
    engine.gfx.tone_mapping_filter.apply_filter(cmd) catch |err| {
        std.log.warn("Unable to apply tone mapping filter: {}", .{err});
    };

    // Render to LDR buffer
    if (self.current_mode == .Edit) {
        self.edit_mode.render_cmd(cmd) catch |err| {
            std.log.warn("Unable to render edit mode: {}", .{err});
        };
    }

    if (!engine.imui.has_focus() and engine.input.get_key(KeyCode.C)) {
        engine.physics.debug_draw_bodies(
            cmd,
            camera_projection_matrix,
            camera_view_matrix,
        );
    }

    engine.debug.render_cmd(cmd, render_camera) catch |err| {
        std.log.warn("Unable to render debug: {}", .{err});
    };

    engine.imui.render_imui(cmd) catch |err| {
        std.log.warn("Unable to render imui: {}", .{err});
    };

    // Finish command buffer
    cmd.cmd_end() catch |err| {
        std.log.warn("Failed to end command buffer: {}", .{err});
        return;
    };

    const uber_semaphore = &self.uber_cmd_semaphores[gfx.GfxState.get().current_frame_index()];
    engine.gfx.submit_command_buffer(.{
        .command_buffers = &.{ cmd },
        .wait_semaphores = &.{ .{
            .semaphore = &image_available_semaphore,
            .dst_stage = gfx.PipelineStageFlags{ .color_attachment_output = true, },
        } },
        .signal_semaphores = &.{ uber_semaphore },
    }) catch |err| {
        std.log.warn("Unable to submit command buffer: {}", .{err});
        return;
    };

    // Present
    engine.gfx.present(&.{ uber_semaphore }) catch |err| {
        std.log.err("Unable to present frame: {}", .{err});
        return;
    };
}

pub fn push_all_entities_for_rendering(
    self: *Self,
) !void {
    var bone_arena = std.heap.ArenaAllocator.init(eng.get().frame_allocator);
    defer bone_arena.deinit();

    // Iterate through all entities finding those which contain a mesh to be rendered
    for (eng.get().entities.list.data.items, 0..) |*it, entity_id| {
        if (it.item_data) |*entity| {
            try self.push_entity_for_rendering(bone_arena.allocator(), entity, entity_id);
            _ = bone_arena.reset(.retain_capacity);
        }
    }
}

pub fn push_entity_for_rendering(
    self: *Self,
    alloc: std.mem.Allocator,
    entity: *eng.entity.EntitySuperStruct,
    entity_id: usize,
) !void {
    try self.push_entity_model_for_rendering(alloc, entity, entity_id);

    if (entity.app.light) |*light| {
        light.position = entity.transform.position;
        light.direction = entity.transform.forward_direction();
        self.standard_renderer.push_light(light.*) catch |err| {
            std.log.warn("Unable to push light '{s}' for rendering: {}", .{
                entity.name orelse "unknown",
                err
            });
        };
    }

    if (entity.app.particle_system) |*ps| {
        self.particles_renderer.push_particle_system(ps) catch |err| {
            std.log.warn("Unable to push particle system '{s}' for rendering: {}", .{
                entity.name orelse "unknown",
                err
            });
        };
    }
}

pub fn push_entity_model_for_rendering(
    self: *Self,
    alloc: std.mem.Allocator,
    entity: *eng.entity.EntitySuperStruct,
    entity_id: usize,
) !void {
    const engine = eng.get();

    if (entity.model) |mid| {
        const m = engine.asset_manager.get_asset(assets.ModelAsset, mid) catch unreachable;

        const pose = try alloc.alloc(zm.Mat, eng.mesh.MAX_BONES);
        defer alloc.free(pose);
        @memset(pose, zm.identity());

        const bone_info = blk: {
            if (entity.app.anim_controller) |*anim_controller| {
                anim_controller.update(&engine.asset_manager, &engine.time);
                anim_controller.calculate_bone_transforms(
                    eng.get().general_allocator,
                    &engine.asset_manager,
                    m,
                    pose
                );

                const bone_index_info = self.standard_renderer.push_bones(pose[0..]) catch unreachable;

                break :blk StandardRenderer.AnimatedRenderObject.BoneInfo {
                    .bone_count = pose.len,
                    .bone_offset = bone_index_info.start_idx,
                };
            } else {
                break :blk null;
            }
        };

        // Finally, render the model
        self.render_model(
            @truncate(entity_id),
            m,
            if (bone_info) |bi| 
            .{
                .pose_data = pose,
                .bone_info = bi,
            }
            else null,
            entity.transform
        ) catch unreachable;
    } else {
        if (self.current_mode == .Edit) {
            const sphere_asset_id = engine.asset_manager.find_asset_id(assets.ModelAsset, "core|sphere") catch unreachable;
            const m = engine.asset_manager.get_asset(assets.ModelAsset, sphere_asset_id) catch unreachable;
            self.render_model(
                @truncate(entity_id),
                m,
                null,
                entity.transform
            ) catch unreachable;
        }
    }
}

pub fn render_model(
    self: *Self,
    entity_id: u32,
    model: *const eng.mesh.Model,
    bones_data: ?struct {
        pose_data: []const zm.Mat,
        bone_info: StandardRenderer.AnimatedRenderObject.BoneInfo,
    },
    transform: Transform,
) !void {
    const node_matrix_list = try eng.get().general_allocator.alloc(zm.Mat, model.nodes.len);
    defer eng.get().general_allocator.free(node_matrix_list);

    const root_transform = transform.generate_model_matrix();

    for (model.nodes, 0..) |*node, node_index| {
        const parent_matrix = if (node.parent) |parent_node_index| blk: {
            std.debug.assert(parent_node_index < node_index);
            break :blk node_matrix_list[parent_node_index];
        } else root_transform;

        var node_model_matrix = zm.mul(node.transform.generate_model_matrix(), parent_matrix);

        // Apply pose
        if (bones_data) |bd| {
            if (node.name) |node_name| {
                if (model.bones_names_map.get(node_name)) |bone_id| {
                    const bone_data = &model.bones_info[@intCast(bone_id)];
                    // @TODO: this inverse does not need to happen, work to remove this if performance becomes an issue
                    node_model_matrix = zm.mul(zm.mul(zm.inverse(bone_data.bone_offset_matrix), bd.pose_data[@intCast(bone_id)]), root_transform);
                }
            }
        }

        // Render mesh set
        if (node.mesh_set) |*mesh_set| {
            for (mesh_set.primitives_slice()) |prim_index| {
                const mesh_prim = &model.meshes[prim_index];

                var material = eng.mesh.MaterialTemplate {};
                if (mesh_prim.material_template) |m_idx| {
                    material = model.materials[m_idx];
                }

                const indices_info = blk: { if (mesh_prim.has_indices()) {
                    break :blk StandardRenderer.RenderObject.IndexInfo {
                        .buffer_info = .{ 
                            .buffer = model.indices_buffer,
                            .offset = @intCast(mesh_prim.indices_offset),
                        },
                        .index_count = mesh_prim.index_count,
                    };
                } else {
                    break :blk null;
                } };

                var render_object = StandardRenderer.RenderObject {
                    .entity_id = entity_id,
                    .transform = node_model_matrix,
                    .vertex_buffers = undefined,
                    .vertex_count = mesh_prim.vertex_count,
                    .pos_offset = 0,
                    .index_buffer = indices_info,
                    .material = material,
                };
                render_object.vertex_buffers[0] = .{ .buffer = model.vertices_buffer, .offset = mesh_prim.vertices_offset, };
                render_object.vertex_buffers_count = 1;

                if (bones_data) |bd| {
                    self.standard_renderer.push_animated(.{
                        .standard = render_object,
                        .bone_info = bd.bone_info,
                    }) catch unreachable;
                } else {
                    self.standard_renderer.push(render_object)
                        catch unreachable;
                }
            }
        }

        node_matrix_list[node_index] = node_model_matrix;
    }
}

pub fn window_event_received(self: *Self, event: *const window.WindowEvent) void {
    switch (event.*) {
        .EVENTS_CLEARED => {
            self.update() catch |err| {
                std.log.err("update failed: {}", .{err});
            };
        },
        else => {},
    }
}

fn character_is_supported(chr: *zphy.CharacterVirtual) bool {
    return chr.getGroundState() == zphy.CharacterGroundState.on_ground;
}

fn character_anim_description() anim.AnimController.Descriptor {
    const engine = eng.get();
    
    const character_animation_idle_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.idle")
        catch unreachable;
    const character_animation_walk_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.walk")
        catch unreachable;
    const character_animation_run_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.run")
        catch unreachable;
    const character_animation_attack_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.attack")
        catch unreachable;

    var anim_nodes = [_]anim.Node{
        .{
            .node = .{ .Basic = .{
                .animation = character_animation_idle_id,
            } },
            .next = &[_]anim.NodeTransition{
                anim.NodeTransition{
                    .node = 1,
                    .condition = anim.TransitionCondition{ .Float = .{
                        .variable_id = anim.AnimController.hash_variable("character speed"),
                        .comparison = .GreaterThan,
                        .value = 0.05,
                    } },
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
                anim.NodeTransition{
                    .node = 2,
                    .condition = anim.TransitionCondition{ .Event = .{
                        .variable_id = anim.AnimController.hash_variable("character attack"),
                    } },
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
            },
        },
        .{
            .node = .{ .Blend1D = .{
                .left_animation = character_animation_walk_id,
                .right_animation = character_animation_run_id,
                .variable = anim.AnimController.hash_variable("character speed"),
                .left_value = 4.0,
                .right_value = 8.0,
                .left_strength_variable = anim.AnimController.hash_variable("character walk speed norm"),
            } },
            .next = &[_]anim.NodeTransition{
                anim.NodeTransition{
                    .node = 0,
                    .condition = anim.TransitionCondition{ .Float = .{
                        .variable_id = anim.AnimController.hash_variable("character speed"),
                        .comparison = .LessThan,
                        .value = 0.05,
                    } },
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
                anim.NodeTransition{
                    .node = 2,
                    .condition = anim.TransitionCondition{ .Event = .{
                        .variable_id = anim.AnimController.hash_variable("character attack"),
                    } },
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
            },
        },
        .{
            .node = .{ .Basic = .{
                .animation = character_animation_attack_id,
            } },
            .next = &[_]anim.NodeTransition{
                anim.NodeTransition{
                    .node = 0,
                    .condition = anim.TransitionCondition.Always,
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
            },
        },
    };

    return anim.AnimController.Descriptor {
        .nodes = anim_nodes[0..],
        .base_animation = character_animation_idle_id,
    };
}
