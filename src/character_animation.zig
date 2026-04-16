const std = @import("std");
const eng = @import("engine");
const assets = eng.assets;
const anim = eng.animation_controller;
const es = eng.util.easings;

pub fn setup_character_anim_controller(anim_controller: *anim.AnimController) !void {
    const engine = eng.get();
    
    const character_animation_idle_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.idle")
        catch unreachable;
    const character_animation_walk_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.walk")
        catch unreachable;
    const character_animation_run_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.run")
        catch unreachable;
    const character_animation_attack_id = engine.asset_manager.find_asset_id(assets.AnimationAsset, "default|character.attack")
        catch unreachable;

    const alloc = eng.get().general_allocator;

    const anim_nodes = [_]anim.Node{
        .{
            .node = .{ .Basic = .{
                .animation = character_animation_idle_id,
            } },
            .next = try alloc.dupe(anim.NodeTransition, &[_]anim.NodeTransition{
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
            }),
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
            .next = try alloc.dupe(anim.NodeTransition, &[_]anim.NodeTransition{
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
            }),
        },
        .{
            .node = .{ .Basic = .{
                .animation = character_animation_attack_id,
            } },
            .next = try alloc.dupe(anim.NodeTransition, &[_]anim.NodeTransition{
                anim.NodeTransition{
                    .node = 0,
                    .condition = anim.TransitionCondition.Always,
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
            }),
        },
    };

    anim_controller.clear_nodes();
    try anim_controller.nodes.appendSlice(alloc, anim_nodes[0..]);

    anim_controller.base_animation = character_animation_idle_id;
}
