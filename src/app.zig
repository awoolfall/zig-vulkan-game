const Self = @This();

const std = @import("std");

const en = @import("engine");
const engine = en.engine;
const Engine = en.Engine;

const zphy = en.physics.zphy;
const zm = en.zmath;
const Transform = en.Transform;
const gfx = en.gfx;
const window = en.window;
const input = en.input;
const KeyCode = en.input.KeyCode;
const cm = en.camera;
const ms = en.mesh;
const gen = en.gen;
const ph = en.physics;
const path = en.path;
const particle = en.particles;
const es = en.easings;
const anim = en.animation;
const assets = en.assets;
const sr = en.serialize;

const Terrain = @import("terrain/terrain.zig");
const Gizmo = @import("gizmo/gizmo.zig");
const SelectionTextures = @import("selection_textures.zig");
const DepthTextures = @import("depth_textures.zig");
const StandardRenderer = @import("render.zig");

const ui = en.ui;
const FontEnum = ui.FontEnum;

const gitrev = en.gitrev;
const gitchanged = en.gitchanged;

pub const EntityData = struct {
    health_points: ?i32,
    anim_controller: ?anim.AnimController,

    pub fn deinit(self: *EntityData) void {
        if (self.anim_controller) |*anim_controller| {
            anim_controller.deinit();
        }
    }

    pub fn init(desc: Descriptor) !EntityData {
        return EntityData {
            .health_points = desc.health_points,
            .anim_controller = if (desc.anim_controller_desc) |anim_desc| try anim.AnimController.init(engine().general_allocator.allocator(), anim_desc) else null,
        };
    }

    pub fn descriptor(self: *const EntityData, alloc: std.mem.Allocator) !Descriptor {
        const anim_desc = if (self.anim_controller) |ac| try ac.descriptor(alloc) else null;
        errdefer if (anim_desc) |ad| alloc.free(ad);

        return Descriptor {
            .health_points = self.health_points,
            .anim_controller_desc = anim_desc,
        };
    }

    pub const Descriptor = struct {
        health_points: ?i32 = null,
        anim_controller_desc: ?anim.AnimController.Descriptor = null,
    };
};

depth_textures: DepthTextures,
selection_textures: SelectionTextures,
selected_entity: ?gen.GenerationalIndex = null,

camera: cm.Camera,
camera_type: enum { FLY, ORBIT } = .ORBIT,
target_old_pos: zm.F32x4 = zm.f32x4s(0.0),

character_idx: gen.GenerationalIndex,
opponent_idx: gen.GenerationalIndex,
//character_ignore_self_filter: *ph.IgnoreIdsBodyFilter,

app_life_asset_pack_id: assets.AssetPackId,
turntable_model_id: assets.ModelAssetId,

imui: ui.Imui,

zero_particle_system: particle.ParticleSystem,
player_attack_particle_system: particle.ParticleSystem,

exposure: f32 = 2.0,

checkbox_bool: bool = false,
slider_float: f32 = 0.0,
text_input_state: ui.Imui.TextInputState,

terrain: Terrain,
gizmo: Gizmo,
standard_renderer: StandardRenderer,

pub fn deinit(self: *Self) void {
    std.log.info("App deinit!", .{});

    engine().gfx.flush();
    self.imui.deinit();
    self.zero_particle_system.deinit();
    self.player_attack_particle_system.deinit();

    engine().asset_manager.unload_asset_pack(self.app_life_asset_pack_id)
        catch unreachable;

    self.depth_textures.deinit();
    self.selection_textures.deinit();

    self.text_input_state.deinit();

    self.terrain.deinit();
    self.gizmo.deinit();
    self.standard_renderer.deinit();
}

pub fn init(self: *Self) !void {
    std.log.info("App init!", .{});
    var depth_textures = try DepthTextures.init(&engine().gfx);
    errdefer depth_textures.deinit();

    var selection_textures = try SelectionTextures.init(&engine().gfx);
    errdefer selection_textures.deinit();

    var asset_pack = try assets.AssetPack.init(engine().general_allocator.allocator(), "default");
    defer asset_pack.deinit();

    //try asset_pack.add_model("character", assets.AssetPack.ModelAsset{ .Path = "character rigify.glb" });
    try asset_pack.add_model("character", assets.AssetPack.ModelAsset{ .Path = "KayKit_Adventure/Characters/gltf/Knight.glb" });
    try asset_pack.add_model("model", assets.AssetPack.ModelAsset{ .Path = "sea_house.glb" });
    try asset_pack.add_model("terrain", assets.AssetPack.ModelAsset{ .Plane = .{ .slices = 1, .stacks = 1, } });
    try asset_pack.add_model("cone", assets.AssetPack.ModelAsset{ .Cone = .{ .slices = 8, } });
    try asset_pack.add_model("sphere", assets.AssetPack.ModelAsset{ .Sphere = .{ .subdivisions = 2, } });

    try asset_pack.define_animation("character idle", "character", 36);
    try asset_pack.define_animation("character run", "character", 48);
    try asset_pack.define_animation("character walk", "character", 72);
    try asset_pack.define_animation("character attack", "character", 1);

    // try asset_pack.define_animation("character idle", "character", 0);
    // try asset_pack.define_animation("character run", "character", 1);
    // try asset_pack.define_animation("character walk", "character", 2);
    // try asset_pack.define_animation("character attack", "character", 2);

    const asset_pack_id = try engine().asset_manager.load_asset_pack(&asset_pack, &engine().gfx);
    
    const character_model_id = engine().asset_manager.find_model_id("character").?;
    const terrain_model_id = engine().asset_manager.find_model_id("terrain").?;
    const turntable_model_id = engine().asset_manager.find_model_id("model").?;

    const character_animation_idle_id = engine().asset_manager.find_animation_id("character idle").?;
    const character_animation_walk_id = engine().asset_manager.find_animation_id("character walk").?;
    const character_animation_run_id = engine().asset_manager.find_animation_id("character run").?;
    const character_animation_attack_id = engine().asset_manager.find_animation_id("character attack").?;

    const character_model = engine().asset_manager.get_model(character_model_id) catch unreachable;
    std.log.info("character model animations:", .{});
    for (character_model.animations, 0..) |*animation, i| {
        std.log.info("{}. anim: {s}", .{i, animation.name});
    }

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
    const anim_desc = anim.AnimController.Descriptor {
        .nodes = anim_nodes[0..],
        .base_animation = character_animation_idle_id,
    };

    // Use the model as a 'prefab' of sorts and create a number of entities from its nodes
    const terrain_shape = try engine().physics.create_shape(ph.ShapeSettings {
        // .shape = .{ .Box = .{
        //     .width = 100.0,
        //     .height = 0.5,
        //     .depth = 100.0,
        // } },
        // .offset_transform = Transform {
        //     .position = zm.f32x4(50.0, -0.25, -50.0, 0.0),
        // },
        .shape = .{ .ModelCompoundConvexHull = terrain_model_id },
        .offset_transform = Transform {
            .scale = zm.f32x4(100.0, 1.0, 100.0, 0.0),
        },
    });
    defer terrain_shape.release();

    _ = try engine().entities.new_entity(Engine.EntityDescriptor {
        .name = "ground entity",
        .should_serialize = true,
        .model = "default|terrain",
        .physics = .{ .Body = .{
            .settings = .{
                .shape = .{ .Box = .{
                    .width = 100.0,
                    .height = 1.0,
                    .depth = 100.0,
                }, },
                .offset_transform = .{
                    //.position = zm.f32x4(-50.0, -5.0, 50.0, 1.0),
                },
            },
            .is_static = true,
        }, },
        .transform = Transform {
            .scale = zm.f32x4s(100.0),
        },
    });

    const chara_transform = Transform {
        .position = zm.f32x4(-0.5, -3.0, 0.5, 1.0),
    };

    // const chara_shape_settings = try zphy.CapsuleShapeSettings.create(0.7, 0.2);
    // defer chara_shape_settings.release();
    //
    // const chara_offset_shape_settings = try zphy.DecoratedShapeSettings.createRotatedTranslated(
    //     @ptrCast(chara_shape_settings), 
    //     zm.qidentity(), 
    //     [3]f32{0.0, chara_shape_settings.getHalfHeight() + chara_shape_settings.getRadius(), 0.0}
    // );
    // defer chara_offset_shape_settings.release();
    //
    // const chara_shape = try chara_offset_shape_settings.createShape();
    // defer chara_shape.release();

    // if (engine().physics.init_body_write_lock(chara_ent.physics..?)) |write_lock| {
    //     defer write_lock.deinit();
    //
    //     write_lock.body.getMotionPropertiesMut().setInverseMass(1.0 / 70.0);
    //     // disables rotation somehow (from jolt 3.0.1 Character.cpp line 45)
    //     write_lock.body.getMotionPropertiesMut().setInverseInertia([3]f32{0.0, 0.0, 0.0}, zm.qidentity());
    //     write_lock.body.setFriction(0.0);
    // } else |_| {}
    
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

    const chara_root_idx = try engine().entities.new_entity(Engine.EntityDescriptor {
        .name = "character entity",
        .should_serialize = true,
        .model = "default|character",
        .transform = Transform {
            .position = zm.f32x4(0.0, 10.0, 0.0, 0.0),
        },
        .physics = .{ .CharacterVirtual = .{
            .settings = character_virtual_settings,
            .create_character = true,
        } },
        .app = .{
            .health_points = 100,
            .anim_controller_desc = anim_desc,
        },
    });
    // const chara_body_id_character = engine().entities.list.get(chara_root_idx).?.physics.?.CharacterVirtual.character.?.getBodyId();
    //
    // // @TODO this body filter needs to be stored on the entity alongside character/virtual character...
    // const character_ignore_self_filter = try engine().general_allocator.allocator().create(ph.IgnoreIdsBodyFilter);
    // errdefer engine().general_allocator.allocator().destroy(character_ignore_self_filter);
    // character_ignore_self_filter.* = ph.IgnoreIdsBodyFilter.init(&[1]zphy.BodyId{chara_body_id_character});
    // engine().entities.list.get(chara_root_idx).?.physics.?.CharacterVirtual.body_filter = @ptrCast(character_ignore_self_filter);

    const character_settings = ph.CharacterSettings {
        .base = ph.CharacterBaseSettings {
            .up = [4]f32{0.0, 1.0, 0.0, 0.0},
            .max_slope_angle = 70.0,
            .shape = chara_shape,
        },
        .layer = ph.object_layers.moving,
        .mass = 70.0,
        .friction = 0.0,
        .gravity_factor = 0.0,
    };

    const opponent_idx = try engine().entities.new_entity(Engine.EntityDescriptor {
        .name = "opponent entity",
        .should_serialize = true,
        .model = "default|character",
        .transform = chara_transform,
        .physics = .{ .Character = .{
            .settings = character_settings,
        } },
        .app = .{
            .health_points = 100,
            .anim_controller_desc = anim_desc,
        },
    });

    // for (0..100) |_| {
    //     chara_transform.position += zm.f32x4(0.0, 0.5, 0.0, 0.0);
    //     _ = try engine().entities.new_entity(Engine.EntityDescriptor {
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
    
    // if (engine().entities.get(opponent_idx)) |op| {
    //     var rand = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    //     op.app.anim_controller.?.base_animation_time = rand.random().float(f64) * 10.0;
    // }

    _ = try engine().entities.new_entity(Engine.EntityDescriptor {
        .name = "cone entity",
        .should_serialize = true,
        .model = "default|cone",
        .transform = .{
            .position = zm.f32x4(0.0, 10.0, 0.0, 0.0),
        },
    });

    engine().physics.zphy.optimizeBroadPhase();

    var imui = try ui.Imui.init(engine().general_allocator.allocator(), &engine().input, &engine().time, &engine().window, &engine().gfx);
    errdefer imui.deinit();

    var zero_particle_system = try particle.ParticleSystem.init(
        engine().general_allocator.allocator(),
        2000,
        .{
            .alignment = .{ .VelocityAligned = 150.0 },
            .shape = .Circle,
            .spawn_origin = zm.f32x4(0.0, -4.0, 0.0, 0.0),
            .spawn_offset = zm.f32x4s(0.0),
            .spawn_radius = 1.0,
            .spawn_rate = 0.01,
            .spawn_rate_variance = 0.01,
            .burst_count = 1,
            .particle_lifetime = 10.0,
            .initial_velocity = zm.f32x4(0.0, 0.0, 0.0, 0.0),
            .scale = .{
                .{ .value = zm.f32x4s(0.02), .key_time = 0.0, },
                .{ .value = zm.f32x4s(0.02), .key_time = 0.95, },
                .{ .value = zm.f32x4s(0.0), .key_time = 1.0, },
                null
            },
            .colour = .{
                // .{ .value = zm.srgbToRgb(zm.f32x4(90.0/255.0, 195.0/255.0, 232.0/255.0, 0.0)) * zm.f32x4(1.0, 1.0, 1.0, 1.0), .key_time = 0.0, },
                // .{ .value = zm.srgbToRgb(zm.f32x4(90.0/255.0, 195.0/255.0, 232.0/255.0, 1.0)) * zm.f32x4(1.0, 1.0, 1.0, 1.0), .key_time = 0.05, },
                .{ .value = zm.srgbToRgb(zm.f32x4(90.0/255.0, 195.0/255.0, 232.0/255.0, 0.0)) * zm.f32x4(60.0, 60.0, 60.0, 1.0), .key_time = 0.0, },
                .{ .value = zm.srgbToRgb(zm.f32x4(90.0/255.0, 195.0/255.0, 232.0/255.0, 1.0)) * zm.f32x4(60.0, 60.0, 60.0, 1.0), .key_time = 0.05, },
                null,
                null,
            },
            .forces = .{
                //.{ .Constant = zm.f32x4(0.0, -9.8, 0.0, 0.0) },
                .{ .Curl = 0.05 },
                .{ .Drag = 1.0 },
                .{ .Vortex = .{ .axis = zm.f32x4(1.0, 0.0, 0.0, 0.0), .force = 1.0, .origin_pull = 0.5,  } },
                null,
            },
        },
        &engine().gfx
    );
    errdefer zero_particle_system.deinit();

    var player_attack_particle_system = try particle.ParticleSystem.init(
        engine().general_allocator.allocator(),
        60,
        .{
            .alignment = .{ .VelocityAligned = 5.0 },
            .shape = .Circle,
            .spawn_origin = zm.f32x4(0.0, 0.0, 0.0, 0.0),
            .spawn_offset = zm.f32x4s(0.0),
            .spawn_radius = 1.0,
            .spawn_rate = 0.0,
            .spawn_rate_variance = 0.0,
            .burst_count = 60,
            .particle_lifetime = 1.0,
            .scale = .{
                .{ .value = zm.f32x4s(0.05), },
                null,
                null,
                null,
            },
            .colour = .{
                .{ .value = zm.srgbToRgb(zm.f32x4(0.0, 0.0, 0.0, 1.0)), .key_time = 0.0, },
                .{ .value = zm.srgbToRgb(zm.f32x4(0.0, 0.0, 0.0, 0.0)), .key_time = 1.0, .easing_into = .OutLinear },
                null,
                null,
                // .{ .value = zm.hsvToRgb(zm.f32x4(0.0, 1.0, 1.0, 1.0)), .key_time = 0.0, },
                // .{ .value = zm.hsvToRgb(zm.f32x4(0.5, 1.0, 1.0, 1.0)), .key_time = 0.5, },
                // .{ .value = zm.hsvToRgb(zm.f32x4(0.999, 1.0, 1.0, 1.0)), .key_time = 1.0, },
                // null
            },
            .forces = .{
                .{ .Vortex = .{ .axis = zm.f32x4(0.0, 1.0, 0.0, 0.0), .force = 50.0, .origin_pull = 50.0, } },
                .{ .Drag = 5.0 },
                null,
                null,
            },
        },
        &engine().gfx
    );
    errdefer player_attack_particle_system.deinit();

    var terrain = try Terrain.init(engine().general_allocator.allocator(), &engine().physics, &engine().gfx);
    errdefer terrain.deinit();

    var gizmo = try Gizmo.init(engine().general_allocator.allocator(), &engine().gfx);
    errdefer gizmo.deinit();

    self.* = Self {
        .depth_textures = depth_textures,
        .selection_textures = selection_textures,

        .camera = cm.Camera {
            .field_of_view_y = 20.0,
            .near_field = 0.3,
            .far_field = 1000.0,
            .move_speed = 10.0,
            .mouse_sensitivity = 0.001,
            .max_orbit_distance = 10.0,
            .min_orbit_distance = 1.0,
            .orbit_distance = 5.0,
        },

        .character_idx = chara_root_idx,
        .opponent_idx = opponent_idx,

        //.character_ignore_self_filter = character_ignore_self_filter,

        .app_life_asset_pack_id = asset_pack_id,
        .turntable_model_id = turntable_model_id,

        .imui = imui,
        .zero_particle_system = zero_particle_system,
        .player_attack_particle_system = player_attack_particle_system,

        .text_input_state = ui.Imui.TextInputState.init(engine().general_allocator.allocator()),

        .terrain = terrain,
        .gizmo = gizmo,
        .standard_renderer = try StandardRenderer.init(),
    };
}

fn vecAngle(v0: zm.F32x4, v1: zm.F32x4) f32 {
    const angle = std.math.acos(zm.dot3(v0, v1)[0] / (zm.length3(v0)[0] * zm.length3(v1)[0]));
    if (std.math.isNan(angle)) {
        return 0.0;
    }
    return angle;
}

fn vecProject(v0: zm.F32x4, v1: zm.F32x4) f32 {
    return zm.length3(v0)[0] * std.math.cos(vecAngle(v0, v1));
}

fn forward_vector_2d(transform: *const Transform) zm.F32x4 {
    var forward_direction = transform.forward_direction();
    forward_direction[1] = 0.0;
    return zm.normalize3(forward_direction);
}

fn update(self: *Self) void {
    // It's pretty important we clear these so we will defer that here
    defer self.standard_renderer.clear();

    // render some ui
    const top_layout = self.imui.push_floating_layout(.Y, 500, 100, .{@src()});
    if (self.imui.get_widget(top_layout)) |top_widget| {
        top_widget.flags.render = true;
        top_widget.background_colour = self.imui.palette().background;
        top_widget.border_colour = self.imui.palette().border;
        top_widget.border_width_px = 2;
        top_widget.padding_px = .{
            .left = 10,
            .right = 10,
            .top = 10,
            .bottom = 10,
        };
        top_widget.corner_radii_px = .{
            .top_left = 10,
            .top_right = 10,
            .bottom_left = 10,
            .bottom_right = 10,
        };
        top_widget.children_gap = 5.0;
    }
    const columns_layout = self.imui.push_layout(.X, .{@src()});
    if (self.imui.get_widget(columns_layout)) |columns_widget| {
        columns_widget.children_gap = 20.0;
    }

    const labels_layout = self.imui.push_layout(.Y, .{@src()});
    self.imui.get_widget(labels_layout).?.children_gap = 5.0;
    self.imui.pop_layout();
    const buttons_layout = self.imui.push_layout(.Y, .{@src()});
    self.imui.get_widget(buttons_layout).?.children_gap = 5.0;
    self.imui.pop_layout();
    self.imui.push_layout_id(labels_layout);
    _ = self.imui.label("Option 1:");
    self.imui.pop_layout();
    self.imui.push_layout_id(buttons_layout);
    const b1 = self.imui.badge("Option 1 button", .{@src()});
    if (self.imui.get_widget(b1.id.box)) |w| {
        w.semantic_size[0].kind = .ParentPercentage;
        w.semantic_size[0].value = 1.0;
    }
    if (b1.clicked) {
        std.log.info("b1 clicked!", .{});
    }
    self.imui.pop_layout();
    self.imui.push_layout_id(labels_layout);
    _ = self.imui.label("Option 2 longlonglonglonglonglonglonglong:");
    self.imui.pop_layout();
    self.imui.push_layout_id(buttons_layout);
    const b2 = self.imui.badge("Option 2 button", .{@src()});
    if (self.imui.get_widget(b2.id.box)) |w| {
        w.semantic_size[0].kind = .ParentPercentage;
        w.semantic_size[0].value = 1.0;
    }
    if (b2.clicked) {
        std.log.info("b2 clicked!", .{});
    }
    self.imui.pop_layout();
    self.imui.push_layout_id(labels_layout);
    _ = self.imui.label("Option 3:");
    if (self.imui.checkbox(self.checkbox_bool, "this is a checkbox", .{@src()}).clicked) {
        self.checkbox_bool = !self.checkbox_bool;
    }
    const slider = self.imui.slider(self.slider_float, 0.0, 1.0, .{@src()});
    if (slider.dragged) {
        if (self.imui.get_widget_from_last_frame(slider.id.background_bar)) |b| {
            const pixel_width: f32 = @floatFromInt(b.content_rect().width);
            const percent = @as(f32, @floatFromInt(engine().input.cursor_position[0] - b.computed.rect().left)) / pixel_width;
            self.slider_float = std.math.clamp(percent, 0.0, 1.0);
        }
    }
    self.imui.pop_layout();
    self.imui.push_layout_id(buttons_layout);
    if (self.imui.badge("Option 3 button longlonglong", .{@src()}).clicked) {
        std.log.info("b3 clicked!", .{});
    }
    const bs = self.imui.button("Option button", .{@src()});
    if (bs.clicked) {
        std.log.info("button clicked!", .{});
    }
    self.imui.pop_layout();
    self.imui.pop_layout();
    _ = self.imui.line_edit(&self.text_input_state, .{@src()});
    self.imui.pop_layout();

    const anim_debug_layout = self.imui.push_floating_layout(.Y, 10.0, 100.0, .{@src()});
    if (self.imui.get_widget(anim_debug_layout)) |w| {
        w.flags.render = true;
        w.background_colour = self.imui.palette().background;
        w.border_colour = self.imui.palette().border;
        w.border_width_px = 1;
        w.corner_radii_px = .{
            .top_left = 10,
            .top_right = 10,
            .bottom_left = 10,
            .bottom_right = 10,
        };
        w.children_gap = 5;
        w.padding_px = .{
            .left = 10,
            .right = 10,
            .top = 10,
            .bottom = 10,
        };
    }
    _ = self.imui.label("Anim debug:");
    self.imui.pop_layout();

    // exposure panel
    const exposure_float_layout_id = self.imui.push_floating_layout(
        .Y, 
        @floatFromInt(engine().gfx.swapchain_size.width - 250),
        @floatFromInt(engine().gfx.swapchain_size.height - 200),
        .{@src()}
    );
    if (self.imui.get_widget(exposure_float_layout_id)) |ex_w| {
        ex_w.flags.render = true;
        ex_w.background_colour = self.imui.palette().background;
        ex_w.border_colour = self.imui.palette().border;
        ex_w.border_width_px = 1;
        ex_w.corner_radii_px = .{
            .top_left = 10,
            .top_right = 10,
            .bottom_left = 10,
            .bottom_right = 10,
        };
        ex_w.children_gap = 5;
        ex_w.padding_px = .{
            .left = 10,
            .right = 10,
            .top = 10,
            .bottom = 10,
        };
    }
    if (self.imui.badge("Set camera pos to scene", .{@src()}).clicked) {
    }
    _ = self.imui.label("Camera view matrix:");
    _ = self.imui.push_layout(.X, .{@src()});
    var camera_pos_text: [256]u8 = [_]u8{0} ** 256;
    _ = std.fmt.bufPrint(camera_pos_text[0..], "{d:.1}\n{d:.1}", .{
        self.camera.transform.position,
        self.camera.transform.rotation,
    }) catch unreachable;
    const cam_pos_lbl = self.imui.label(camera_pos_text[0..]);
    if (self.imui.get_widget(cam_pos_lbl.id)) |ww| {
        ww.text_content.?.font = .GeistMono;
    }
    self.imui.pop_layout();
    self.imui.pop_layout();

    _ = self.imui.push_floating_layout(.Y, 300, 0, .{@src()});
    const save_scene_button = self.imui.button("Save Scene", .{@src()});
    if (save_scene_button.clicked) {
        save_entities_to_scene("scene") catch |err| {
            std.log.err("Failed to save scene entities: {}", .{err});
        };
    }
    const load_scene_button = self.imui.button("Load Scene", .{@src()});
    if (load_scene_button.clicked) {
        create_scene_entities("scene") catch |err| {
            std.log.err("Failed to create scene entities: {}", .{err});
        };
    }
    self.imui.pop_layout();

    // new entity button
    if (engine().input.get_key_down(KeyCode.E)) {
        _ = engine().entities.new_entity(Engine.EntityDescriptor {
            .name = "new entity",
            .should_serialize = true,
            .model = "default|sphere",
            .transform = Transform {
                .position = self.camera.transform.position + zm.normalize3(self.camera.transform.forward_direction()),
            },
        }) catch |err| {
            std.log.err("Failed to create entity: {}", .{err});
        };
    }

    // Input to move the model around
    if (engine().entities.get(self.character_idx)) |character_entity| {
        var movement_direction = zm.f32x4s(0.0);
        if (engine().input.get_key(KeyCode.W)) {
            movement_direction[2] += 1.0;
        }
        if (engine().input.get_key(KeyCode.S)) {
            movement_direction[2] -= 1.0;
        }
        if (engine().input.get_key(KeyCode.D)) {
            movement_direction[0] += 1.0;
        }
        if (engine().input.get_key(KeyCode.A)) {
            movement_direction[0] -= 1.0;
        }

        const camera_right = self.camera.transform.right_direction();
        const camera_forward_no_pitch = zm.cross3(camera_right, zm.f32x4(0.0, 1.0, 0.0, 0.0));

        movement_direction = 
            camera_forward_no_pitch * zm.f32x4s(movement_direction[2])
            + camera_right * zm.f32x4s(movement_direction[0]);

        if (@reduce(.Add, @abs(movement_direction)) != 0.0) {
            movement_direction = zm.normalize3(movement_direction);
        }
        if (engine().input.get_key(KeyCode.Shift)) {
            movement_direction *= zm.f32x4s(2.0);
        }

        // disable movement when attacking
        if (character_entity.app.anim_controller) |*ac| {
            if (ac.active_node == 2) {
                movement_direction *= zm.f32x4s(0.0);
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
                + movement_direction * zm.f32x4s(character_movement_speed * friction * engine().time.delta_time_f32())
                // apply friction
                - character_velocity * zm.f32x4s(friction * engine().time.delta_time_f32());
        } else {
            // if not supported then apply gravity
            character_velocity = character_velocity
                + zm.loadArr3(engine().physics.zphy.getGravity()) * zm.f32x4s(engine().time.delta_time_f32());
        }

        character.setLinearVelocity(zm.vecToArr3(character_velocity));

        // Rotate character model to match the input desired direction
        // If no input desired direction (normalized to nan) then remain in last rotation
        const dir = zm.normalize3(movement_direction);
        if (!std.math.isNan(dir[0])) {
            const rot = zm.lookAtRh(zm.f32x4s(0.0), dir * zm.f32x4(1.0, 1.0, -1.0, 0.0), zm.f32x4(0.0, 1.0, 0.0, 0.0));
            character.setRotation(
                zm.slerp(character_entity.transform.rotation, zm.matToQuat(rot), engine().time.delta_time_f32() * 15.0)
            );
        }

        if (engine().input.get_key_down(KeyCode.MouseLeft)) {
            var collector = CollideShapeCollector.init(engine().frame_allocator);
            defer collector.deinit();

            const box_shape_settings = zphy.BoxShapeSettings.create([3]f32{0.5, 0.5, 0.5}) catch unreachable;
            defer box_shape_settings.release();

            const box_shape = box_shape_settings.createShape() catch unreachable;
            defer box_shape.release();

            var camera_forward_2d = self.camera.transform.forward_direction();
            camera_forward_2d[1] = 0.0;
            camera_forward_2d = zm.normalize3(camera_forward_2d);

            const shape_position = character_entity.transform.position + zm.f32x4(0.0, 0.6, 0.0, 0.0) + (camera_forward_2d);
            
            const matrix = zm.matToArr((Transform {
                    .position = shape_position
                }).generate_model_matrix());

            if (engine().input.get_key(KeyCode.Control)) {
                if (engine().entities.get(self.opponent_idx)) |opponent_entity| {
                    if (opponent_entity.app.anim_controller) |*ac| {
                        ac.trigger_event("character attack");
                    }
                }
            } else {
                if (character_entity.app.anim_controller) |*ac| {
                    ac.trigger_event("character attack");
                }
            }

            // particles!
            self.player_attack_particle_system.settings.spawn_origin = shape_position;
            self.player_attack_particle_system.settings.spawn_offset = camera_right;
            self.player_attack_particle_system.settings.initial_velocity = zm.f32x4s(0.0); //camera_forward_2d * zm.f32x4s(10.0);
            self.player_attack_particle_system.emit_particle_burst();

            engine().physics.zphy.getNarrowPhaseQuery().collideShape(
                box_shape,
                [3]f32{1.0, 1.0, 1.0},
                matrix,
                [3]zphy.Real{0.0, 0.0, 0.0},
                @ptrCast(&collector),
                .{}
            );

            std.log.info("hits: {}", .{collector.hits.items.len});
            for (collector.hits.items) |hit| {
                var read_lock = engine().physics.init_body_read_lock(hit.body2_id) catch unreachable;
                defer read_lock.deinit();

                const user_data = ph.PhysicsSystem.extract_entity_from_user_data(read_lock.body.getUserData());
                if (engine().entities.get(user_data.entity)) |entity| {
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
    }

    // // Cast ray from camera
    // if (engine().entities.get(self.camera_idx)) |camera_entity| {
    //     var raycast_result = engine().physics.zphy.getNarrowPhaseQuery().castRay(.{
    //         .origin = camera_entity.transform.position,
    //         .direction = camera_entity.transform.forward_direction(),
    //     }, .{});
    //     if (raycast_result.has_hit) {
    //         std.log.info("  raycast hit! id:{}", .{raycast_result.hit.body_id});
    //     }
    // }

    // Update physics. If frame time is greater than 1 second then skip physics for this frame.
    // @TODO: It is most likely we loaded something in and caused a spike... Fix this permanently 
    // by adding async loads and/or loading screens.

    var target_pos = zm.f32x4s(0.0);
    if (engine().entities.get(self.character_idx)) |character_entity| {
        target_pos = character_entity.transform.position + zm.f32x4(0.0, 1.5, 0.0, 0.0);

        // {
        //     self.imui.push_layout_id(anim_debug_layout);
        //     defer self.imui.pop_layout();
        //     var anim_name: [128]u8 = [_]u8{0} ** 128;
        //     _ = self.imui.label("Anim controller debug:");
        //     const default_anim = engine().asset_manager.get_animation(self.anim_controller.nodes[0].node.Basic.animation) catch unreachable;
        //     const default_anim_name_string = std.fmt.bufPrint(anim_name[0..], "Default Animation: {s}", .{default_anim.name}) catch unreachable;
        //     _ = self.imui.label(default_anim_name_string);
        //     _ = self.imui.slider(@floatCast(default_anim.current_tick / default_anim.duration_ticks), 0.0, 1.0, .{@src(), 0});
        //     const active_node_string = std.fmt.bufPrint(anim_name[0..], "Active Node: {d}", .{self.anim_controller.active_node}) catch unreachable;
        //     _ = self.imui.label(active_node_string);
        //     switch (self.anim_controller.nodes[self.anim_controller.active_node].node) {
        //         .Blend1D => |*b1d| {
        //             _ = self.imui.label("Blend1D Node");
        //             _ = self.imui.label("blend amount:");
        //             _ = self.imui.slider(@floatCast((self.anim_controller.get_variable_by_id(b1d.variable.?).? - b1d.left_value) / (b1d.right_value - b1d.left_value)), 0.0, 1.0, .{@src(), 0});
        //             const left_anim = engine().asset_manager.get_animation(b1d.left_animation) catch unreachable;
        //             const right_anim = engine().asset_manager.get_animation(b1d.right_animation) catch unreachable;
        //             const left_anim_name_string = std.fmt.bufPrint(anim_name[0..], "Left Animation: {s}", .{left_anim.name}) catch unreachable;
        //             _ = self.imui.label(left_anim_name_string);
        //             _ = self.imui.slider(@floatCast(left_anim.current_tick / left_anim.duration_ticks), 0.0, 1.0, .{@src(), 0});
        //             _ = self.imui.label("Left animation strength:");
        //             _ = self.imui.slider(@floatCast(self.anim_controller.get_variable_by_id(b1d.left_strength_variable orelse 0) orelse 1.0), 0.0, 1.0, .{@src(), 0});
        //             const right_anim_name_string = std.fmt.bufPrint(anim_name[0..], "Right Animation: {s}", .{right_anim.name}) catch unreachable;
        //             _ = self.imui.label(right_anim_name_string);
        //             _ = self.imui.slider(@floatCast(right_anim.current_tick / right_anim.duration_ticks), 0.0, 1.0, .{@src(), 0});
        //             _ = self.imui.label("Right animation strength:");
        //             _ = self.imui.slider(@floatCast(self.anim_controller.get_variable_by_id(b1d.right_strength_variable orelse 0) orelse 1.0), 0.0, 1.0, .{@src(), 0});
        //         },
        //         .Basic => |*b| {
        //             _ = self.imui.label("Basic Node");
        //             _ = self.imui.label("animation strength:");
        //             _ = self.imui.slider(@floatCast(self.anim_controller.get_variable_by_id(b.strength_variable orelse 0) orelse 1.0), 1.0, 1.0, .{@src(), 0});
        //         },
        //     }
        // }
        
        const character_velocity = zm.loadArr3(character_entity.physics.?.CharacterVirtual.virtual.getLinearVelocity());
        if (character_entity.app.anim_controller) |*ac| {
            ac.set_variable("character speed", zm.length3(character_velocity)[0]);
            ac.set_variable("character walk speed norm", std.math.clamp(zm.length3(character_velocity)[0] / 4.0, 0.0, 1.0));
        }
    }

    var bone_transforms: []zm.Mat = engine().frame_allocator.alloc(zm.Mat, ms.MAX_BONES) catch unreachable;
    var null_bone_transforms: []zm.Mat = engine().frame_allocator.alloc(zm.Mat, ms.MAX_BONES) catch unreachable;
    @memset(null_bone_transforms[0..], zm.identity());
    // Iterate through all entities finding those which contain a mesh to be rendered
    for (engine().entities.list.data.items, 0..) |*it, entity_id| {
        if (it.item_data) |*entity| {
            // Find the transform of the entity to be rendered taking into account it's parent
            if (entity.model) |mid| {
                const m = engine().asset_manager.get_model(mid) catch unreachable;

                var pose: []zm.Mat = null_bone_transforms;
                const bone_info = blk: { if (entity.app.anim_controller) |*anim_controller| {
                    anim_controller.update(&engine().asset_manager, &engine().time);
                    anim_controller.calculate_bone_transforms(
                        &engine().asset_manager,
                        m,
                        bone_transforms
                    );

                    pose = bone_transforms;

                    const bone_index_info = self.standard_renderer.push_bones(bone_transforms[0..]) catch unreachable;

                    break :blk StandardRenderer.AnimatedRenderObject.BoneInfo {
                        .bone_count = bone_transforms.len,
                        .bone_offset = bone_index_info.start_idx,
                    };
                } else {
                    break :blk null;
                }};

                // Finally, render the model
                self.recursive_render_model(
                    @truncate(entity_id),
                    m, 
                    pose,
                    bone_info,
                    &entity.transform.generate_model_matrix(), 
                    &m.nodes_list[m.root_nodes[0]],
                    entity.transform.generate_model_matrix()
                );
            }
        }
    }

    // render sea house scene
    {
        const m = engine().asset_manager.get_model(self.turntable_model_id) catch unreachable;

        // Finally, render the model
        const tt = Transform{ .scale = zm.f32x4s(0.05) };
        self.recursive_render_model(
            0,
            m, 
            null,
            null,
            &tt.generate_model_matrix(), 
            &m.nodes_list[m.root_nodes[0]],
            tt.generate_model_matrix()
        );
    }

    // update camera
    if (engine().input.get_key_down(KeyCode.P)) {
        if (self.camera_type == .ORBIT) {
            self.camera_type = .FLY;
        } else {
            self.camera_type = .ORBIT;
        }
    }
    if (self.camera_type == .FLY) {
        self.camera.fly_camera_update(&engine().window, &engine().input, &engine().time);
    } else {
        self.camera.orbit_camera_update(target_pos, &engine().window, &engine().input, &engine().time);
    }
    const camera_view_matrix = self.camera.transform.generate_view_matrix();

    // Draw frame
    var rtv = engine().gfx.begin_frame() catch |err| {
        std.log.err("unable to begin frame: {}", .{err});
        return;
    };

    engine().gfx.cmd_clear_render_target(&rtv, zm.srgbToRgb(zm.f32x4(133.0/255.0, 193.0/255.0, 233.0/255.0, 1.0)));
    engine().gfx.cmd_clear_render_target(&self.selection_textures.rtv, zm.f32x4s(0.0));
    engine().gfx.cmd_clear_depth_stencil_view(&self.depth_textures.dsv, 0.0, null);

    self.standard_renderer.update_camera_data_buffer(&self.camera);
    self.standard_renderer.render(
        &rtv, 
        &self.selection_textures.rtv, 
        &self.depth_textures.dsv, 
        .{
            .selected_entity_idx = if (self.selected_entity) |s| s.index else null,
        }
    );

    // render terrain
    self.terrain.render(&self.standard_renderer.camera_data_buffer, &engine().gfx);

    self.zero_particle_system.update(&engine().time);
    self.zero_particle_system.draw(
        camera_view_matrix,
        self.camera.generate_perspective_matrix(engine().gfx.swapchain_aspect()), 
        &rtv,
        &self.depth_textures.dsv_read_only,
        &engine().gfx
    );

    self.player_attack_particle_system.update(&engine().time);
    self.player_attack_particle_system.draw(
        camera_view_matrix,
        self.camera.generate_perspective_matrix(engine().gfx.swapchain_aspect()), 
        &rtv,
        &self.depth_textures.dsv_read_only,
        &engine().gfx
    );

    // find bone transforms for chara
    //
    // if (engine().entities.get(self.character_idx)) |chara| {
    //     engine().gfx.context.ClearDepthStencilView(self.depth_stencil_view, d3d11.CLEAR_FLAG {.CLEAR_DEPTH = true,}, 1, 0);
    //
    //     const pos_stride: c_uint = @sizeOf(f32) * 3;
    //     const tex_coord_stride: c_uint = @sizeOf(f32) * 2;
    //     const bone_id_stride: c_uint = @sizeOf([4]i32);
    //     const bone_weight_stride: c_uint = @sizeOf([4]f32);
    //     const offset: c_uint = 0;
    //     engine().gfx.context.IASetVertexBuffers(0, 1, @ptrCast(&self.cone_model.buffers.positions), @ptrCast(&pos_stride), @ptrCast(&offset));
    //     engine().gfx.context.IASetVertexBuffers(1, 1, @ptrCast(&self.cone_model.buffers.normals), @ptrCast(&pos_stride), @ptrCast(&offset));
    //     engine().gfx.context.IASetVertexBuffers(2, 1, @ptrCast(&self.cone_model.buffers.tex_coords), @ptrCast(&tex_coord_stride), @ptrCast(&offset));
    //     engine().gfx.context.IASetVertexBuffers(3, 1, @ptrCast(&self.cone_model.buffers.bone_ids), @ptrCast(&bone_id_stride), @ptrCast(&offset));
    //     engine().gfx.context.IASetVertexBuffers(4, 1, @ptrCast(&self.cone_model.buffers.bone_weights), @ptrCast(&bone_weight_stride), @ptrCast(&offset));
    //     engine().gfx.context.IASetIndexBuffer(self.cone_model.buffers.indices, zwin32.dxgi.FORMAT.R32_UINT, 0);
    //
    //     // Set model constant buffer
    //     engine().gfx.context.VSSetConstantBuffers(1, 1, @ptrCast(&self.model_buffer));
    //
    //     self.render_model_bones(
    //         &self.cone_model, 
    //         &(Transform {
    //             .scale = zm.f32x4(0.05, 0.2, 0.05, 0.0),
    //             //.rotation = zm.quatFromRollPitchYaw(std.math.degreesToRadians(f32, 90.0), 0.0, 0.0),
    //         }).generate_model_matrix(),
    //         chara.model.?, 
    //         chara.transform.generate_model_matrix(),
    //     );
    // }

    // Draw Physics Debug Wireframes
    if (engine().input.get_key(KeyCode.C)) {
        engine().physics.debug_draw_bodies(
            &rtv, 
            engine().gfx.swapchain_size.width,
            engine().gfx.swapchain_size.height,
            zm.matToArr(self.camera.generate_perspective_matrix(engine().gfx.swapchain_aspect())),
            zm.matToArr(camera_view_matrix),
        );
    }

    var vel_buf: [128]u8 = [_]u8{0} ** 128;
    var vel_text: []u8 = vel_buf[0..0];
    if (engine().entities.get(self.character_idx)) |character_entity| {
        const character = character_entity.physics.?.CharacterVirtual.virtual;
        const character_velocity = zm.loadArr3(character.getLinearVelocity());
        vel_text = std.fmt.bufPrint(vel_buf[0..], "character speed: {d:.2}\nvelocity: {d:.2}\nis supported: {}", .{
            zm.length3(character_velocity)[0],
            character_velocity,
            character_is_supported(character_entity.physics.?.CharacterVirtual.virtual),
        }) catch unreachable;

        {
            _ = self.imui.push_floating_layout(.Y, 100, 500, .{@src()});
            const l = self.imui.label(vel_text);
            if (self.imui.get_widget(l.id)) |tw| {
                tw.text_content.?.font = .GeistMono;
                tw.text_content.?.size = 15;
            }
            _ = self.imui.pop_layout();
        }
    }

    var fps_buf: [128]u8 = [_]u8{0} ** 128;
    const fps_text = std.fmt.bufPrint(fps_buf[0..], "fps: {d:0.1}\nframe time: {d:2.3}ms\nwait time: {d:2.3}ms\nwait %: {d:0.0}", .{
        engine().time.get_fps(),
        (engine().time.delta_time_f32() - engine().time.last_frame_wait_time_s) * std.time.ms_per_s,
        engine().time.last_frame_wait_time_s * std.time.ms_per_s,
        (engine().time.last_frame_wait_time_s / engine().time.last_frame_time_s) * 100.0
    }) catch unreachable;

    {
        _ = self.imui.push_floating_layout(
            .Y, 
            5.0, 
            5.0 - self.imui.get_font(FontEnum.GeistMono).font_metrics.descender * 12.0, 
            .{@src()}
        );
        const l = self.imui.label(fps_text);
        if (self.imui.get_widget(l.id)) |tw| {
            tw.text_content.?.font = .GeistMono;
            tw.text_content.?.size = 12;
        }
        _ = self.imui.pop_layout();
    }

    var rev_buf: [64]u8 = [_]u8{0} ** 64;
    const rev_text = std.fmt.bufPrint(rev_buf[0..], "zig-dx11 - {x}{s}", .{
        gitrev,
        blk: { if (gitchanged) { break :blk "*"; } else { break :blk ""; } },
    }) catch unreachable;
    {
        _ = self.imui.push_floating_layout(.Y, 10.0, @as(f32, @floatFromInt(engine().gfx.swapchain_size.height)) - 
            self.imui.get_font(FontEnum.GeistMono).font_metrics.line_height * 12.0, .{@src()});
        const l = self.imui.label(rev_text);
        if (self.imui.get_widget(l.id)) |tw| {
            tw.text_content.?.font = .GeistMono;
            tw.text_content.?.size = 12;
        }
        _ = self.imui.pop_layout();
    }

    engine().gfx.tone_mapping_filter.apply_filter(&engine().gfx.hdr_texture_view, self.exposure, engine().gfx.get_framebuffer(), &engine().gfx);

    if (self.selected_entity) |s| {
        if (engine().entities.get(s)) |entity| {
            const viewport = gfx.Viewport {
                .width = @floatFromInt(engine().gfx.swapchain_size.width),
                .height = @floatFromInt(engine().gfx.swapchain_size.height),
                .min_depth = 0.0,
                .max_depth = 1.0,
                .top_left_x = 0.0,
                .top_left_y = 0.0,
            };
            engine().gfx.cmd_set_viewport(viewport);
            self.gizmo.update(&entity.transform, zm.inverse(self.camera.generate_perspective_matrix(engine().gfx.swapchain_aspect())), zm.inverse(camera_view_matrix));
            self.gizmo.render(&entity.transform, &self.standard_renderer.camera_data_buffer, engine().gfx.get_framebuffer(), &self.depth_textures.dsv, self.camera.transform.rotation);
        } 
    }

    engine().debug.render(&self.standard_renderer.camera_data_buffer, engine().gfx.get_framebuffer());

    self.imui.compute_widget_rects();
    self.imui.render_imui(engine().gfx.get_framebuffer(), &engine().gfx);
    self.imui.end_frame(&engine().gfx);

    engine().gfx.present() catch |err| {
        std.log.err("unable to present frame: {}", .{err});
        return;
    };

    if (engine().input.get_key_down(KeyCode.MouseLeft) and engine().input.get_key(KeyCode.Shift)) {
        const selection_entity_id = self.selection_textures.get_value_at_position(@intCast(engine().input.cursor_position[0]), @intCast(engine().input.cursor_position[1]), &engine().gfx) catch |err| {
            std.log.err("cannot get value at position: {}", .{err});
            return;
        };

        if (selection_entity_id == 0) {
            self.selected_entity = null;
        } else {
            const entity = engine().entities.get_dont_check_generation(selection_entity_id);
            if (entity) |ent| {
                std.log.info("entity name: {s}", .{ent.name orelse "unnamed"});
                self.selected_entity = .{
                    .index = selection_entity_id,
                    .generation = engine().entities.list.data.items[selection_entity_id].generation,
                };
            } else {
                std.log.info("entity not found!", .{});
            }
        }
    }
}

pub fn recursive_render_model(
    self: *Self, 
    entity_id: u32,
    model: *const ms.Model, 
    pose: ?[]const zm.Mat, 
    bone_info: ?StandardRenderer.AnimatedRenderObject.BoneInfo,
    root_mat: *const zm.Mat,
    model_node: *const ms.ModelNode, 
    mat: zm.Mat
) void {
    var node_model_matrix = zm.mul(model_node.transform.generate_model_matrix(), mat);

    // Apply pose
    if (pose) |p| {
        if (model_node.name) |node_name| {
            if (model.bone_mapping.get(node_name)) |bone_id| {
                const bone_data = &model.bone_info.items[@intCast(bone_id)];
                // @TODO: this inverse does not need to happen, work to remove this if performance becomes an issue
                node_model_matrix = zm.mul(zm.mul(zm.inverse(bone_data.bone_offset), p[@intCast(bone_id)]), root_mat.*);
            }
        }
    }

    if (model_node.mesh) |*mesh_set| {
        for (mesh_set.primitives) |maybe_prim| {
            if (maybe_prim) |prim_idx| {
                const p = &model.mesh_list[prim_idx];

                var material = ms.MaterialTemplate {};
                if (p.material_template) |m_idx| {
                    material = model.materials[m_idx];
                }

                const indices_info = blk: { if (p.has_indices()) {
                    break :blk StandardRenderer.RenderObject.IndexInfo {
                        .buffer_info = .{ .buffer = &model.buffers.indices, .stride = @truncate(@sizeOf(u32)), .offset = @truncate(p.indices_offset), },
                        .index_count = p.num_indices,
                    };
                } else {
                    break :blk null;
                } };

                const render_object = StandardRenderer.RenderObject {
                    .entity_id = entity_id,
                    .transform = node_model_matrix,
                    .vertex_buffers = std.BoundedArray(gfx.VertexBufferInput, 6).fromSlice(&[_]gfx.VertexBufferInput{
                        .{ .buffer = &model.buffers.vertices, .stride = @truncate(model.buffers.strides.positions), .offset = @truncate(model.buffers.offsets.positions), },
                        .{ .buffer = &model.buffers.vertices, .stride = @truncate(model.buffers.strides.normals), .offset = @truncate(model.buffers.offsets.normals), },
                        .{ .buffer = &model.buffers.vertices, .stride = @truncate(model.buffers.strides.texcoords), .offset = @truncate(model.buffers.offsets.texcoords), },
                        .{ .buffer = &model.buffers.vertices, .stride = @truncate(model.buffers.strides.bone_ids), .offset = @truncate(model.buffers.offsets.bone_ids), },
                        .{ .buffer = &model.buffers.vertices, .stride = @truncate(model.buffers.strides.bone_weights), .offset = @truncate(model.buffers.offsets.bone_weights), },
                    }) catch unreachable,
                    .vertex_count = p.num_vertices,
                    .pos_offset = p.pos_offset,
                    .index_buffer = indices_info,
                    .material = material,
                };

                if (bone_info) |bi| {
                    self.standard_renderer.push_animated(.{
                        .standard = render_object,
                        .bone_info = bi,
                    }) catch unreachable;
                } else {
                    self.standard_renderer.push(render_object)
                        catch unreachable;
                }
            }
        }
    }

    for (model_node.children) |c| {
        self.recursive_render_model(entity_id, model, pose, bone_info, root_mat, &model.nodes_list[c], node_model_matrix);
    }
}

pub fn render_model_bones(
    self: *Self, 
    render_model: *const ms.Model, 
    render_model_transform: *const zm.Mat, 
    model: *const ms.Model, 
    mat: zm.Mat,
) void {
    const global_transform = zm.inverse(model.global_inverse_transform);
    for (model.nodes_list) |*node| {
        if (node.name) |node_name| {
            if (model.bone_mapping.get(node_name)) |bone_id| {
                const bone_data = &model.bone_info.items[@intCast(bone_id)];

                const node_model_matrix_transformed = 
                    zm.mul(
                        zm.inverse(bone_data.bone_offset), 
                        zm.mul(
                            bone_data.final_transform, 
                            zm.mul(global_transform, mat)
                        )
                    );

                self.recursive_render_model(
                    render_model, 
                    null,
                    &render_model.nodes_list[render_model.root_nodes[0]], 
                    zm.mul(render_model_transform.*, node_model_matrix_transformed)
                );
            }
        }
    }
}

pub fn window_event_received(self: *Self, event: *const window.WindowEvent) void {
    switch (event.*) {
        .EVENTS_CLEARED => { self.update(); },
        .RESIZED => |new_size| {
            if (new_size.width > 0 and new_size.height > 0) {
                self.selection_textures.on_resize(&engine().gfx);
                self.depth_textures.on_resize(&engine().gfx);
            }
        },
        else => {},
    }
}

fn character_is_supported(chr: *zphy.CharacterVirtual) bool {
    return chr.getGroundState() == zphy.CharacterGroundState.on_ground;
}

const CollideShapeCollector = extern struct {
    usingnamespace zphy.CollideShapeCollector.Methods(@This());
    __v: *const zphy.CollideShapeCollector.VTable = &vtable,

    hits: *std.ArrayList(zphy.CollideShapeResult),

    const vtable = zphy.CollideShapeCollector.VTable{ 
        .reset = _Reset,
        .onBody = _OnBody,
        .addHit = _AddHit,
    };

    fn _Reset(
        self: *zphy.CollideShapeCollector,
    ) callconv(.C) void { 
        _ = self;
    }
    fn _OnBody(
        self: *zphy.CollideShapeCollector,
        in_body: *const zphy.Body,
    ) callconv(.C) void { 
        _ = self;
        _ = in_body;
    }
    fn _AddHit(
        self: *zphy.CollideShapeCollector,
        collide_shape_result: *const zphy.CollideShapeResult,
    ) callconv(.C) void {
        @as(*CollideShapeCollector, @ptrCast(self)).hits.append(collide_shape_result.*) catch unreachable;
    }

    pub fn deinit(self: *CollideShapeCollector) void {
        self.hits.deinit();
        self.hits.allocator.destroy(self.hits);
    }

    pub fn init(alloc: std.mem.Allocator) CollideShapeCollector {
        const hits = alloc.create(std.ArrayList(zphy.CollideShapeResult)) catch unreachable;
        hits.* = std.ArrayList(zphy.CollideShapeResult).init(alloc);
        return CollideShapeCollector {
            .hits = hits,
        };
    }
};

fn create_scene_entities(scene_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(engine().general_allocator.allocator());
    defer arena.deinit();

    var dir = try std.fs.cwd().openDir(scene_name, .{.iterate = true,});
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        _ = arena.reset(.retain_capacity);
        if (entry.kind == .file) {
            const ent_file = dir.openFile(entry.name, .{}) catch |err| {
                std.log.err("Failed to open file {s}: {}", .{ entry.name, err });
                continue;
            };
            defer ent_file.close();

            const ent_str = ent_file.readToEndAlloc(arena.allocator(), 1024 * 1024) catch |err| {
                std.log.err("Failed to read file {s}: {}", .{ entry.name, err });
                continue;
            };
            defer arena.allocator().free(ent_str);

            const ent_s = std.json.parseFromSliceLeaky(
                sr.Serializable(Engine.EntityDescriptor),
                arena.allocator(),
                ent_str,
                .{ .ignore_unknown_fields = true, }
            ) catch |err| {
                std.log.err("Failed to parse file {s}: {}", .{ entry.name, err });
                continue;
            };

            const ent = sr.deserialize(Engine.EntityDescriptor, arena.allocator(), ent_s) catch |err| {
                std.log.err("Failed to deserialize entity {s}: {}", .{ entry.name, err });
                continue;
            };

            const loaded_entity = engine().entities.new_entity(ent) catch |err| {
                std.log.err("Failed to create entity {s}: {}", .{ entry.name, err });
                continue;
            };
            std.log.info("Loaded entity: {}", .{engine().entities.get(loaded_entity).?});
        }
    }
}

fn save_entities_to_scene(scene_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(engine().general_allocator.allocator());
    defer arena.deinit();

    std.fs.cwd().deleteTree(scene_name) catch |err| {
        std.debug.print("unable to delete scene {s}: {}\n", .{scene_name, err});
    };

    var scene_dir: std.fs.Dir = undefined;
    scene_dir = std.fs.cwd().openDir(scene_name, .{.iterate = true,}) catch blk: {
        try std.fs.cwd().makeDir(scene_name);
        break :blk try std.fs.cwd().openDir(scene_name, .{.iterate = true,});
    };
    defer scene_dir.close();

    var it = engine().entities.list.iterator();

    var largest_serialize_id: u32 = 0;
    while (it.next()) |entity| {
        if (!entity.should_serialize) continue;
        largest_serialize_id = @max(largest_serialize_id, entity.serialize_id orelse 0);
    }

    it.reset();
    while (it.next()) |entity| {
        if (!entity.should_serialize) continue;
        _ = arena.reset(.retain_capacity);

        entity.serialize_id = entity.serialize_id orelse blk: {
            largest_serialize_id += 1;
            break :blk largest_serialize_id;
        };

        const entity_descriptor = entity.descriptor(arena.allocator()) catch |err| {
            std.log.err("unable to produce descriptor for entity {}: {}\n", .{entity.serialize_id.?, err});
            continue;
        };

        const entity_s = sr.serialize(Engine.EntityDescriptor, arena.allocator(), entity_descriptor) catch |err| {
            std.log.err("unable to produce serializable for entity {}: {}\n", .{entity.serialize_id.?, err});
            continue;
        };

        const res = std.json.stringifyAlloc(arena.allocator(), entity_s, .{.whitespace = .indent_2}) catch |err| {
            std.log.err("unable to produce json for entity {}: {}\n", .{entity.serialize_id.?, err});
            continue;
        };
        const file_path = std.fmt.allocPrint(arena.allocator(), "{d}.json", .{entity.serialize_id.?}) catch |err| {
            std.log.err("unable to produce file path for entity {}: {}\n", .{entity.serialize_id.?, err});
            continue;
        };

        scene_dir.writeFile(.{
            .sub_path = file_path,
            .data = res,
            .flags = .{ .read = false, .truncate = true, },
        }) catch |err| {
            std.log.err("unable to write file for entity {}: {}\n", .{entity.serialize_id.?, err});
            continue;
        };
    }
}
