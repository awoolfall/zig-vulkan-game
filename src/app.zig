const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const Imui = eng.Imui;

const KeyCode = eng.input.KeyCode;

const app_ecs = @import("ecs.zig");
const AppResource = @import("app_resource.zig");
const EditMode = @import("edit_mode.zig");
const player = @import("player.zig");
const opponent = @import("opponent.zig");

const gitrev = eng.gitrev;
const gitchanged = eng.gitchanged;

pub export fn app_deinit() i32 {
    deinit() catch |err| {
        std.log.err("App deinit failed: {}", .{err});
        return -1;
    };

    return 0;
}

fn deinit() !void {}

pub export fn app_init() i32 {
    init() catch |err| {
        std.log.err("App init failed: {}", .{err});
        return -1;
    };

    return 0;
}

fn init() !void {
    const __tracy_zone = eng.ztracy.ZoneN(@src(), "app init");
    defer __tracy_zone.End();

    // register app resources
    inline for (.{
        AppResource,
    }) |T| {
        try eng.get().ecs.register_resource(T);
    }

    // register app components
    inline for (app_ecs.EntityComponents) |T| {
        try eng.get().ecs.register_component(T);
    }

    // create standard resources
    try eng.get().ecs.create_resource(eng.Imui);
    try eng.get().ecs.create_resource(eng.physics.PhysicsSystem);
    try eng.get().ecs.create_resource(eng.Debug);

    // create app resources
    try eng.get().ecs.create_resource(AppResource);
}

pub export fn app_update() i32 {
    update() catch |err| {
        std.log.err("App update failed: {}", .{err});
        return 1;
    };

    return 0;
}

fn update() !void {
    const __tracy_zone = eng.ztracy.ZoneN(@src(), "app::update");
    defer __tracy_zone.End();

    const self = try eng.get().ecs.get_resource(AppResource);

    defer self.standard_renderer.clear();
    defer self.particles_renderer.clear();

    const imui = try eng.get().ecs.get_resource(eng.Imui);
    imui.start_new_frame();

    const physics = try eng.get().ecs.get_resource(eng.physics.PhysicsSystem);

    // switch modes
    if (!imui.has_focus() and eng.get().input.get_key_down(KeyCode.F1)) {
        switch (self.current_mode) {
            .Edit => {
                if (self.state) |state| {
                    state.arena.deinit();
                }

                var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
                const entities = EditMode.serialize_entities(&arena, &eng.get().ecs) catch unreachable;
                self.state = .{
                    .arena = arena,
                    .entities = entities,
                };

                self.current_mode = .Play;
                eng.get().time.time_scale = 1.0;
            },
            .Play => {
                self.current_mode = .Edit;
                eng.get().time.time_scale = 0.0;

                if (self.state) |state| {
                    eng.get().ecs.clear_entities();
                    EditMode.load_serialized_entities_into_ecs(&eng.get().ecs, state.entities);
                    self.character_entity = null; // @TODO fix this shouldn't be required. character entity reference should not exist in app...
                }
            },
        }
    }

    var render_camera: *eng.Camera = &self.edit_mode.editor_camera;

    // update
    switch (self.current_mode) {
        .Edit => {
            self.edit_mode.update(&self.standard_renderer.selection_textures, &self.standard_renderer, &self.terrain_renderer, &self.ocean) catch |err| {
                std.log.err("Edit mode update failed: {}", .{err});
            };
            render_camera = switch (self.edit_mode.editor_mode) {
                .SceneEditor => &self.edit_mode.editor_camera,
                .FrameDataEditor => &self.edit_mode.frame_data_editor.camera,
            };

            push_all_entities_for_rendering(self) catch |err| {
                std.log.err("Failed to push all entities for rendering: {}", .{err});
            };
        },
        .Play => {
            blk: {
                if (self.character_entity == null) {
                    // spawn character
                    const character_spawner_entity = eng.get().ecs.find_first_entity_with_name("character-spawner") orelse break :blk;
                    const spawner_transform_component = eng.get().ecs.get_component(eng.ecs.TransformComponent, character_spawner_entity) orelse break :blk;
                    const character_spawner_transform = spawner_transform_component.transform;

                    self.character_entity = player.spawn_character(eng.Transform{
                        .position = character_spawner_transform.position,
                        .rotation = character_spawner_transform.rotation,
                    }, &self.character_animation_graph) catch |err| {
                        std.log.err("Unable to spawn player character: {}", .{err});
                        break :blk;
                    };
                }
            }

            blk: {
                if (eng.get().ecs.get_component_count(app_ecs.OpponentCharacterComponent) == 0) {
                    // spawn character
                    const spawner_entity = eng.get().ecs.find_first_entity_with_name("opponent-spawner") orelse break :blk;
                    const spawner_transform_component = eng.get().ecs.get_component(eng.ecs.TransformComponent, spawner_entity) orelse break :blk;
                    const spawner_transform = spawner_transform_component.transform;

                    _ = opponent.spawn_opponent_character(.{
                        .position = spawner_transform.position,
                        .rotation = spawner_transform.rotation,
                    }, &self.character_animation_graph) catch |err| {
                        std.log.err("Unable to spawn opponent character: {}", .{err});
                        break :blk;
                    };
                }
            }

            player.player_control_system() catch |err| {
                std.log.err("Unable to update player control: {}", .{err});
            };

            opponent.opponent_behaviour_system() catch |err| {
                std.log.err("Unable to update opponent characters: {}", .{err});
            };

            var vel_buf: [128]u8 = [_]u8{0} ** 128;
            var vel_text: []u8 = vel_buf[0..0];
            if (self.character_entity) |character_entity| blk: {
                const physics_runtime_component = eng.get().ecs.get_component(eng.ecs.PhysicsRuntimeComponent, character_entity) orelse break :blk;
                const character = physics_runtime_component.runtime_data.CharacterVirtual.virtual;
                const character_velocity = zm.loadArr3(character.getLinearVelocity());
                vel_text = std.fmt.bufPrint(vel_buf[0..], "character speed: {d:.2}\nvelocity: {d:.2}", .{
                    zm.length3(character_velocity)[0],
                    character_velocity,
                }) catch unreachable;

                {
                    _ = imui.push_floating_layout(.Y, 100, 500, .{@src()});
                    const l = Imui.widgets.label.create(imui, vel_text);
                    if (imui.get_widget(l.id)) |tw| {
                        tw.text_content.?.font = .GeistMono;
                        tw.text_content.?.size = 15;
                        tw.text_content.?.colour = imui.palette().text_dark;
                    }
                    _ = imui.pop_layout();
                }
            }

            // update camera position to track the character entity's visual location
            blk: {
                var camera_query = eng.get().ecs.query_iterator(.{ app_ecs.CameraComponent, eng.ecs.TransformComponent });
                const camera_component: *app_ecs.CameraComponent, const camera_transform: *eng.ecs.TransformComponent = camera_query.next() orelse break :blk;

                var target_pos = zm.f32x4s(0.0);
                if (self.character_entity) |character_entity| {
                    const visual_transform = physics.calculate_entity_visual_transform(character_entity);
                    const camera_right = camera_transform.transform.right_direction();
                    target_pos = visual_transform.position + zm.f32x4(0.0, 1.5, 0.0, 0.0) + camera_right * zm.f32x4s(1.0);
                }

                camera_component.camera_data.orbit_camera_update(target_pos, &eng.get().os, &eng.get().input, &eng.get().time);
                camera_transform.transform = camera_component.camera_data.transform; // TODO: we shouldn't use two transforms. convert camera update to use ecs

                render_camera = &camera_component.camera_data;
            }

            try push_all_entities_for_rendering(self);
        },
    }

    // update particle systems
    var particle_system_iter = eng.get().ecs.query_iterator(.{ eng.ecs.TransformComponent, app_ecs.ParticleSystemComponent });
    while (particle_system_iter.next()) |components| {
        const entity_transform: *eng.ecs.TransformComponent, const entity_particle_system: *app_ecs.ParticleSystemComponent = components;

        entity_particle_system.particle_system.settings.spawn_origin = entity_transform.transform.position;
        entity_particle_system.particle_system.update(&eng.get().time);
    }

    var fps_buf: [128]u8 = [_]u8{0} ** 128;
    const fps_text = std.fmt.bufPrint(fps_buf[0..], "fps: {d:0.1}\nframe time: {d:2.3}ms\nwait time: {d:2.3}ms\nwait %: {d:0.0}", .{
        eng.get().time.get_fps(),
        (1.0 / eng.get().time.get_fps()) * std.time.ms_per_s,
        eng.get().time.last_frame_wait_time_s * std.time.ms_per_s,
        (eng.get().time.last_frame_wait_time_s / eng.get().time.last_frame_time_s) * 100.0,
    }) catch unreachable;

    {
        _ = imui.push_floating_layout(.Y, 5.0, 25.0 + imui.get_font(eng.Imui.FontEnum.GeistMono).font_metrics.descender * 12.0, .{@src()});
        const l = Imui.widgets.label.create(imui, fps_text);
        if (imui.get_widget(l.id)) |tw| {
            tw.text_content.?.font = .GeistMono;
            tw.text_content.?.size = 12;
            tw.text_content.?.colour = imui.palette().text_dark;
        }
        _ = imui.pop_layout();
    }

    var rev_buf: [64]u8 = [_]u8{0} ** 64;
    const rev_text = std.fmt.bufPrint(rev_buf[0..], "zig-dx11 - {x}{s}", .{
        gitrev,
        if (gitchanged) "*" else "",
    }) catch unreachable;
    {
        _ = imui.push_floating_layout(.Y, 10.0, @as(f32, @floatFromInt(eng.get().gfx.swapchain_size()[1])) -
            imui.get_font(eng.Imui.FontEnum.GeistMono).font_metrics.line_height * 12.0, .{@src()});
        const l = Imui.widgets.label.create(imui, rev_text);
        if (imui.get_widget(l.id)) |tw| {
            tw.text_content.?.font = .GeistMono;
            tw.text_content.?.size = 12;
            tw.text_content.?.colour = imui.palette().text_dark;
        }
        _ = imui.pop_layout();
    }

    // Update animation times
    var animation_component_iterator = eng.get().ecs.query_iterator(.{eng.ecs.AnimationControllerComponent});
    while (animation_component_iterator.next()) |components| {
        const component = components.@"0";
        component.control_data.active_time += eng.get().time.delta_time_f32();
        eng.AnimationGraph.update(component.graph, &component.control_data);
    }

    // Draw frame
    const camera_view_matrix = render_camera.transform.generate_view_matrix();
    const camera_projection_matrix = render_camera.generate_perspective_matrix(eng.get().gfx.swapchain_aspect());

    const frame_ready_semaphore = eng.get().gfx.begin_frame() catch |err| {
        std.log.warn("Unable to begin frame: {}", .{err});
        return;
    };

    const frame_idx = eng.get().time.frame_number % 4;
    var cmd = &self.command_buffers[@intCast(frame_idx)];

    cmd.reset() catch |err| {
        std.log.warn("Unable to reset command buffer: {}", .{err});
        return;
    };
    cmd.cmd_begin(.{ .one_time_submit = true }) catch |err| {
        std.log.warn("Unable to begin command buffer: {}", .{err});
        return;
    };

    // Derive sun direction from first sun light in scene
    const atm_sun_dir: [3]f32 = blk: {
        var light_query = eng.get().ecs.query_iterator(.{app_ecs.LightComponent});
        while (light_query.next()) |components| {
            const lc = components.@"0";
            if (lc.light.light_type == .Sun) {
                const d = zm.normalize3(lc.light.direction);
                break :blk .{ d[0], d[1], d[2] };
            }
        }
        break :blk .{ 0.267, 0.856, 0.445 };
    };

    // Update per-frame atmosphere LUTs before geometry renders
    self.atmosphere.update_luts(cmd, render_camera, atm_sun_dir);
    self.atmosphere.update_cubemap(cmd, render_camera.transform.position[1] / 1000.0, atm_sun_dir);

    // Render to HDR buffer
    // Standard HDR render
    self.standard_renderer.render_cmd(.{
        .camera = render_camera,
    }, cmd) catch |err| {
        std.log.warn("Unable to render standard renderer: {}", .{err});
    };

    // render terrains
    var terrain_query_iterator = eng.get().ecs.query_iterator(.{ app_ecs.TerrainComponent, eng.ecs.TransformComponent });
    while (terrain_query_iterator.next()) |components| {
        const terrain_component: *app_ecs.TerrainComponent = components.@"0";
        const transform_component: *eng.ecs.TransformComponent = components.@"1";

        self.terrain_renderer.render(cmd, render_camera, &terrain_component.terrain, transform_component.transform, &self.standard_renderer);
    }

    // push cloud volumes for rendering
    var cloud_volume_query_iterator = eng.get().ecs.query_iterator(.{ app_ecs.CloudVolumeComponent, eng.ecs.TransformComponent });
    while (cloud_volume_query_iterator.next()) |components| {
        const transform_component: *eng.ecs.TransformComponent = components.@"1";

        self.clouds.push_cloud_volume(.{
            .min = zm.vecToArr3(transform_component.transform.position - transform_component.transform.scale),
            .max = zm.vecToArr3(transform_component.transform.position + transform_component.transform.scale),
            .phase_function = 1,
        });
    }

    self.ocean.update_images(cmd);
    self.ocean.render(&self.standard_renderer, render_camera, cmd);

    self.particles_renderer.push_particle_system(&self.player_attack_particle_system) catch |err| {
        std.log.warn("Unable to push particle system '{s}' for rendering: {}", .{ "player attack", err });
    };

    // render particle systems
    self.particles_renderer.render(cmd, render_camera) catch |err| {
        std.log.warn("Unable to render particle systems: {}", .{err});
    };

    // render atmosphere sky (after geometry/ocean, reads depth to discard non-sky pixels)
    self.atmosphere.render(cmd, render_camera, atm_sun_dir);

    // render clouds
    self.clouds.render(cmd, render_camera, &self.standard_renderer) catch |err| {
        std.log.warn("Unable to render clouds: {}", .{err});
    };

    // apply bloom
    eng.get().gfx.bloom_filter.render_bloom(cmd, .{}) catch |err| {
        std.log.warn("Unable to apply bloom filter: {}", .{err});
    };

    // Transition HDR image from colour output attachment to shader resource
    cmd.cmd_pipeline_barrier(eng.gfx.CommandBuffer.PipelineBarrierInfo{
        .src_stage = .{ .color_attachment_output = true },
        .dst_stage = .{ .fragment_shader = true },
        .image_barriers = &.{
            eng.gfx.CommandBuffer.ImageMemoryBarrierInfo{
                .image = eng.gfx.GfxState.get().default.hdr_image,
                .old_layout = eng.gfx.ImageLayout.ColorAttachmentOptimal,
                .new_layout = eng.gfx.ImageLayout.ShaderReadOnlyOptimal,
                .src_access_mask = .{ .color_attachment_write = true },
                .dst_access_mask = .{ .shader_read = true },
            },
        },
    });

    // Tonemap HDR image onto LDR buffer
    eng.get().gfx.tone_mapping_filter.apply_filter(cmd) catch |err| {
        std.log.warn("Unable to apply tone mapping filter: {}", .{err});
    };

    // Render to LDR buffer
    if (self.current_mode == .Edit) {
        self.edit_mode.render_cmd(cmd);
    }

    if (!imui.has_focus() and eng.get().input.get_key(KeyCode.C)) {
        physics.debug_draw_bodies(
            cmd,
            camera_projection_matrix,
            camera_view_matrix,
        );
    }

    if (eng.get().ecs.get_resource(eng.Debug) catch null) |db| {
        db.render_cmd(cmd, render_camera) catch |err| {
            std.log.warn("Unable to render debug: {}", .{err});
        };
    }

    imui.render_imui(cmd) catch |err| {
        std.log.warn("Unable to render imui: {}", .{err});
    };

    // Finish command buffer
    cmd.cmd_end() catch |err| {
        std.log.warn("Failed to end command buffer: {}", .{err});
        return;
    };

    const uber_semaphore = &self.uber_cmd_semaphores[eng.get().gfx.current_frame_index()];
    eng.get().gfx.submit_command_buffer(.{
        .command_buffers = &.{cmd},
        .wait_semaphores = &.{.{
            .semaphore = &frame_ready_semaphore,
            .dst_stage = eng.gfx.PipelineStageFlags{ .color_attachment_output = true },
        }},
        .signal_semaphores = &.{uber_semaphore},
    }) catch |err| {
        std.log.warn("Unable to submit command buffer: {}", .{err});
        return;
    };

    // Present
    eng.get().gfx.present(&.{uber_semaphore}) catch |err| {
        std.log.err("Unable to present frame: {}", .{err});
        return;
    };
}

pub fn push_all_entities_for_rendering(
    self: *AppResource,
) !void {
    const __tracy_zone = eng.ztracy.Zone(@src());
    defer __tracy_zone.End();

    var bone_arena = std.heap.ArenaAllocator.init(eng.get().frame_allocator);
    defer bone_arena.deinit();

    const default_model_id = try eng.get().asset_manager.get_asset_id("res:icosphere.glb");
    const defualt_model_component = eng.ecs.ModelComponent{ .model = default_model_id };

    var entity_iterator = eng.get().ecs.entity_iterator();
    while (entity_iterator.next()) |entity| {
        _ = bone_arena.reset(.retain_capacity);
        const transform_component = eng.get().ecs.get_component(eng.ecs.TransformComponent, entity) orelse continue;

        // push entity model for rendering
        blk: {
            const model_component = eng.get().ecs.get_component(eng.ecs.ModelComponent, entity) orelse
                (if (self.current_mode == .Edit) &defualt_model_component else break :blk);
            const maybe_anim_component = eng.get().ecs.get_component(eng.ecs.AnimationControllerComponent, entity);

            const transform = if (eng.get().ecs.resource_exists(eng.physics.PhysicsSystem)) transform_blk: {
                const physics_system = try eng.get().ecs.get_resource(eng.physics.PhysicsSystem);
                break :transform_blk physics_system.calculate_entity_visual_transform(entity);
            } else transform_component.transform;

            self.standard_renderer.push_model(.{
                .model = model_component.model orelse default_model_id,
                .animation_data = if (maybe_anim_component) |ac| .{
                    .animation_graph = ac.graph,
                    .control_data = &ac.control_data,
                } else null,
                .transform = transform,
                .entity_id = @truncate(entity.idx.index),
            }) catch |err| {
                std.log.warn("Unable to push model for rendering: {}", .{err});
                break :blk;
            };
        }

        // push entity light for rendering
        blk: {
            const light_component = eng.get().ecs.get_component(app_ecs.LightComponent, entity) orelse break :blk;

            light_component.light.position = transform_component.transform.position;
            light_component.light.direction = transform_component.transform.forward_direction();

            self.standard_renderer.push_light(light_component.light) catch |err| {
                std.log.warn("Unable to push light '{s}' for rendering: {}", .{ entity.idx.index, err });
                break :blk;
            };
        }

        // push entity particle system for rendering
        blk: {
            const particle_system_component = eng.get().ecs.get_component(app_ecs.ParticleSystemComponent, entity) orelse break :blk;
            self.particles_renderer.push_particle_system(&particle_system_component.particle_system) catch |err| {
                std.log.warn("Failed to push entity particle system for rendering: {}", .{err});
                break :blk;
            };
        }
    }
}
