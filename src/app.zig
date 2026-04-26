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

const ecs = @import("ecs.zig");
const TerrainRenderer = @import("terrain/terrain_renderer.zig");
const StandardRenderer = @import("render.zig");
const Ocean = @import("ocean/ocean.zig");
const Clouds = @import("clouds/clouds.zig");
const EditMode = @import("edit_mode.zig");
const player = @import("player.zig");
const opponent = @import("opponent.zig");

const gitrev = eng.gitrev;
const gitchanged = eng.gitchanged;

pub const EntityComponents = ecs.EntityComponents;

character_entity: ?eng.ecs.Entity = null,
character_animation_graph: eng.AnimationGraph,

player_attack_particle_system: eng.particles.ParticleSystem,

standard_renderer: StandardRenderer,
terrain_renderer: TerrainRenderer,
ocean: Ocean,
clouds: Clouds,
particles_renderer: eng.particles_renderer.ParticleRenderer,

edit_mode: EditMode,
current_mode: enum { Edit, Play } = .Edit,

command_pool: gfx.CommandPool.Ref,
command_buffers: [4]gfx.CommandBuffer,

uber_cmd_semaphores: []gfx.Semaphore,

pub fn deinit(self: *Self) void {
    std.log.info("App deinit!", .{});

    self.player_attack_particle_system.deinit();

    for (self.uber_cmd_semaphores) |s| {
        s.deinit();
    }
    eng.get().general_allocator.free(self.uber_cmd_semaphores);

    self.standard_renderer.deinit();
    self.terrain_renderer.deinit();
    self.ocean.deinit();
    self.clouds.deinit();
    self.particles_renderer.deinit();
    self.edit_mode.deinit();

    for (self.command_buffers[0..]) |c| { c.deinit(); }
    self.command_pool.deinit();

    self.character_animation_graph.deinit();
}

pub fn init() !Self {
    std.log.info("App init!", .{});
    const engine = eng.get();
    
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

    var character_animation_graph = try @import("character_animation.zig").character_animation_graph();
    errdefer character_animation_graph.deinit();

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

    var standard_renderer = try StandardRenderer.init();
    errdefer standard_renderer.deinit();

    var terrain_renderer = try TerrainRenderer.init();
    errdefer terrain_renderer.deinit();

    var ocean = try Ocean.init(.{ .amplitude = 0.08, .wind = .{ 9.0, 0.0 } });
    errdefer ocean.deinit();

    var clouds = try Clouds.init(eng.get().general_allocator);
    errdefer clouds.deinit();

    var particles_renderer = try eng.particles_renderer.ParticleRenderer.init(engine.general_allocator);
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
        .particles_renderer = particles_renderer,
        .edit_mode = edit_mode,

        .command_pool = command_pool,
        .command_buffers = command_buffers,

        .uber_cmd_semaphores = uber_cmd_semaphores,
    };
}

fn update(self: *Self) !void {
    const engine = eng.get();

    const _profile_context = engine.profiler.start_context("app::update");

    // switch modes
    if (!engine.imui.has_focus() and engine.input.get_key_down(KeyCode.F1)) {
        switch (self.current_mode) {
            .Edit => {
                self.current_mode = .Play;
                engine.time.time_scale = 1.0;
            },
            .Play => {
                self.current_mode = .Edit;
                engine.time.time_scale = 0.01;

                blk: {
                    var camera_query = eng.get().ecs.query_iterator(.{ ecs.CameraComponent, eng.ecs.TransformComponent });
                    const camera_component: *ecs.CameraComponent,
                    const camera_transform: *eng.ecs.TransformComponent = camera_query.next() orelse break :blk;

                    _ = camera_component;
                    self.edit_mode.editor_camera.transform = camera_transform.transform;
                }
            },
        }
    }

    var render_camera: *eng.camera.Camera = &self.edit_mode.editor_camera;
    
    // update
    switch (self.current_mode) {
        .Edit => {
            self.edit_mode.update(&self.standard_renderer.selection_textures, &self.terrain_renderer, &self.ocean) catch |err| {
                std.log.err("Edit mode update failed: {}", .{err});
            };
            render_camera = &self.edit_mode.editor_camera;

            self.push_all_entities_for_rendering() catch |err| {
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

                    self.character_entity = player.spawn_character(eng.Transform {
                        .position = character_spawner_transform.position,
                        .rotation = character_spawner_transform.rotation,
                    }, &self.character_animation_graph) catch |err| {
                        std.log.err("Unable to spawn player character: {}", .{err});
                        break :blk;
                    };
                }
            }

            blk: {
                if (eng.get().ecs.get_component_count(ecs.OpponentCharacterComponent) == 0) {
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
                const physics_component = eng.get().ecs.get_component(eng.ecs.PhysicsComponent, character_entity) orelse break :blk;
                const character = physics_component.runtime_data.CharacterVirtual.virtual;
                const character_velocity = zm.loadArr3(character.getLinearVelocity());
                vel_text = std.fmt.bufPrint(vel_buf[0..], "character speed: {d:.2}\nvelocity: {d:.2}", .{
                    zm.length3(character_velocity)[0],
                    character_velocity,
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

            // update camera position to track the character entity's visual location
            blk: {
                var camera_query = eng.get().ecs.query_iterator(.{ ecs.CameraComponent, eng.ecs.TransformComponent });
                const camera_component: *ecs.CameraComponent,
                const camera_transform: *eng.ecs.TransformComponent = camera_query.next() orelse break :blk;

                var target_pos = zm.f32x4s(0.0);
                if (self.character_entity) |character_entity| {
                    const visual_transform = engine.physics.calculate_entity_visual_transform(character_entity);
                    target_pos = visual_transform.position + zm.f32x4(0.0, 1.5, 0.0, 0.0);
                }

                camera_component.camera_data.orbit_camera_update(target_pos, &engine.window, &engine.input, &engine.time);
                camera_transform.transform = camera_component.camera_data.transform; // TODO: we shouldn't use two transforms. convert camera update to use ecs

                render_camera = &camera_component.camera_data;
            }

            try self.push_all_entities_for_rendering();
        },
    }

    // update particle systems
    var particle_system_iter = engine.ecs.query_iterator(.{ eng.ecs.TransformComponent, ecs.ParticleSystemComponent });
    while (particle_system_iter.next()) |components| {
        const entity_transform: *eng.ecs.TransformComponent,
        const entity_particle_system: *ecs.ParticleSystemComponent = components;

        entity_particle_system.particle_system.settings.spawn_origin = entity_transform.transform.position;
        entity_particle_system.particle_system.update(&engine.time);
    }

    // end profile context, usually we can defer this but in app update we have to also print results
    _profile_context.end_context();

    {
        var profiler_text = std.ArrayList(u8).initCapacity(eng.get().frame_allocator, 32) catch unreachable;
        defer profiler_text.deinit(eng.get().frame_allocator);

        profiler_text.appendSlice(eng.get().frame_allocator, "Profiler:\n") catch unreachable;

        for (engine.profiler.contexts_array.items) |context| {
            const context_name = engine.profiler.context_names_map.get(context.name_hash) orelse "unnamed";
            const context_text = std.fmt.allocPrint(eng.get().frame_allocator, 
                "- {s}: {} ms\n", 
                .{
                    context_name,
                    context.result_duration_ms(),
                }
            ) catch unreachable;
            defer eng.get().frame_allocator.free(context_text);

            profiler_text.appendSlice(eng.get().frame_allocator, context_text) catch unreachable;
        }

        _ = engine.imui.push_floating_layout(
            .Y, 
            200.0, 
            25.0 + engine.imui.get_font(FontEnum.GeistMono).font_metrics.descender * 12.0, 
            .{@src()}
        );
        const l = Imui.widgets.label.create(&eng.get().imui, profiler_text.items);
        if (engine.imui.get_widget(l.id)) |tw| {
            tw.text_content.?.font = .GeistMono;
            tw.text_content.?.size = 12;
            tw.text_content.?.colour = eng.get().imui.palette().text_dark;
        }
        _ = engine.imui.pop_layout();
    }

    // end frame here, we record render timing one frame early into next frame's profiler
    engine.profiler.end_frame();

    var fps_buf: [128]u8 = [_]u8{0} ** 128;
    const fps_text = std.fmt.bufPrint(fps_buf[0..], "fps: {d:0.1}\nframe time: {d:2.3}ms\nwait time: {d:2.3}ms\nwait %: {d:0.0}", .{
        engine.time.get_fps(),
        (1.0 / engine.time.get_fps()) * std.time.ms_per_s,
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

    // Update animation times
    var animation_component_iterator = eng.get().ecs.component_iterator(eng.ecs.AnimationControllerComponent);
    while (animation_component_iterator.next()) |component| {
        eng.AnimationGraph.update(component.graph, &component.control_data);
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
        },
        cmd
    ) catch |err| {
        std.log.warn("Unable to render standard renderer: {}", .{err});
    };
    defer self.standard_renderer.clear();

    // render terrains
    var terrain_query_iterator = eng.get().ecs.query_iterator(.{ ecs.TerrainComponent, eng.ecs.TransformComponent });
    while (terrain_query_iterator.next()) |components| {
        const terrain_component: *ecs.TerrainComponent,
        const transform_component: *eng.ecs.TransformComponent = components;

        self.terrain_renderer.render(
            cmd,
            render_camera,
            &terrain_component.terrain,
            transform_component.transform,
            &self.standard_renderer
        );
    }

    // push cloud volumes for rendering
    var cloud_volume_query_iterator = eng.get().ecs.query_iterator(.{ ecs.CloudVolumeComponent, eng.ecs.TransformComponent });
    while (cloud_volume_query_iterator.next()) |components| {
        _, //const cloud_volume_component: *entity_components.CloudVolumeComponent,
        const transform_component: *eng.ecs.TransformComponent = components;

        self.clouds.push_cloud_volume(.{
            .min = zm.vecToArr3(transform_component.transform.position - transform_component.transform.scale),
            .max = zm.vecToArr3(transform_component.transform.position + transform_component.transform.scale),
            .phase_function = 1,
        });
    }

    self.ocean.update_images(cmd);
    self.ocean.render(&self.standard_renderer, render_camera, cmd);

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

    // render clouds
    self.clouds.render(cmd, render_camera, &self.standard_renderer) catch |err| {
        std.log.warn("Unable to render clouds: {}", .{err});
    };

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
        self.edit_mode.render_cmd(cmd);
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

    const _imui_render_profiler_context = engine.profiler.start_context("imui::render");
    engine.imui.render_imui(cmd) catch |err| {
        std.log.warn("Unable to render imui: {}", .{err});
    };
    _imui_render_profiler_context.end_context();

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
    const _present_profiler_context = engine.profiler.start_context("present");
    engine.gfx.present(&.{ uber_semaphore }) catch |err| {
        std.log.err("Unable to present frame: {}", .{err});
        return;
    };
    _present_profiler_context.end_context();
}

pub fn push_all_entities_for_rendering(
    self: *Self,
) !void {
    var bone_arena = std.heap.ArenaAllocator.init(eng.get().frame_allocator);
    defer bone_arena.deinit();

    const default_model_id = try eng.get().asset_manager.get_asset_id("res:block.glb");
    const defualt_model_component = eng.ecs.ModelComponent { .model = default_model_id, };

    var entity_iterator = eng.get().ecs.entity_iterator();
    while (entity_iterator.next()) |entity| {
        _ = bone_arena.reset(.retain_capacity);
        
        // push entity model for rendering
        blk: {
            const model_component = eng.get().ecs.get_component(eng.ecs.ModelComponent, entity) orelse (if (self.current_mode == .Edit) &defualt_model_component else break :blk);
            const maybe_anim_component = eng.get().ecs.get_component(eng.ecs.AnimationControllerComponent, entity);

            const transform = eng.get().physics.calculate_entity_visual_transform(entity);
            
            self.push_model_for_rendering(
                bone_arena.allocator(),
                entity,
                model_component.model orelse defualt_model_component.model.?,
                transform,
                maybe_anim_component
            ) catch |err| {
                std.log.warn("Failed to render entity model: {}", .{err});
                break :blk;
            };
        }

        // push entity light for rendering
        blk: {
            const light_component = eng.get().ecs.get_component(ecs.LightComponent, entity) orelse break :blk;
            const transform_component = eng.get().ecs.get_component(eng.ecs.TransformComponent, entity) orelse break :blk;

            light_component.light.position = transform_component.transform.position;
            light_component.light.direction = transform_component.transform.forward_direction();
            
            self.standard_renderer.push_light(light_component.light) catch |err| {
                std.log.warn("Unable to push light '{s}' for rendering: {}", .{
                    entity.idx.index,
                    err
                });
            };
        }

        // push entity particle system for rendering
        blk: {
            const particle_system_component = eng.get().ecs.get_component(ecs.ParticleSystemComponent, entity) orelse break :blk;
            self.particles_renderer.push_particle_system(&particle_system_component.particle_system) catch |err| {
                std.log.warn("Failed to push entity particle system for rendering: {}", .{err});
                break :blk;
            };
        }
    }
}

pub fn push_model_for_rendering(
    self: *Self,
    alloc: std.mem.Allocator,
    entity: eng.ecs.Entity,
    model: assets.ModelAssetId,
    transform: Transform,
    maybe_anim_controller: ?*eng.ecs.AnimationControllerComponent,
) !void {
    const engine = eng.get();

    const m = engine.asset_manager.get_asset(assets.ModelAsset, model) catch unreachable;

    const pose = try alloc.alloc(zm.Mat, eng.mesh.MAX_BONES);
    defer alloc.free(pose);
    @memset(pose, zm.identity());

    const bone_info = blk: {
        if (maybe_anim_controller) |anim_controller| {
            anim_controller.graph.calculate_bone_transforms(eng.get().general_allocator, m, &anim_controller.control_data, pose);

            const bone_index_info = self.standard_renderer.push_bones(pose[0..]) catch unreachable;

            break :blk StandardRenderer.AnimatedRenderObject.BoneInfo {
                .bone_offset = bone_index_info.start_idx,
                .bone_count = bone_index_info.end_idx - bone_index_info.start_idx,
            };
        } else {
            break :blk null;
        }
    };

    // Finally, render the model
    self.render_model(
        @truncate(entity.idx.index),
        m,
        if (bone_info) |bi| 
        .{
            .pose_data = pose,
            .bone_info = bi,
        }
        else null,
        transform
    ) catch unreachable;
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
