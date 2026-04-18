const std = @import("std");
const eng = @import("engine");
const assets = eng.assets;
const es = eng.util.easings;

pub fn character_animation_graph() !eng.AnimationGraph {
    const character_animation_idle_id = eng.get().asset_manager.find_asset_id(assets.AnimationAsset, "default|character.idle")
        catch unreachable;
    const character_animation_walk_id = eng.get().asset_manager.find_asset_id(assets.AnimationAsset, "default|character.walk")
        catch unreachable;
    const character_animation_run_id = eng.get().asset_manager.find_asset_id(assets.AnimationAsset, "default|character.run")
        catch unreachable;
    const character_animation_attack_id = eng.get().asset_manager.find_asset_id(assets.AnimationAsset, "default|character.attack")
        catch unreachable;

    const anim_nodes = [_]eng.AnimationGraph.Node {
        .{
            .node = .{ .Basic = .{
                .animation = character_animation_idle_id,
            } },
            .next = &[_]eng.AnimationGraph.NodeTransition {
                .{
                    .node = 1,
                    .condition = .{ .Float = .{
                        .variable_id = eng.AnimationGraph.hash_variable("character speed"),
                        .comparison = .GreaterThan,
                        .value = 0.05,
                    } },
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
                .{
                    .node = 2,
                    .condition = .{ .Event = .{
                        .variable_id = eng.AnimationGraph.hash_variable("character attack"),
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
                .variable = eng.AnimationGraph.hash_variable("character speed"),
                .left_value = 4.0,
                .right_value = 8.0,
                .left_strength_variable = eng.AnimationGraph.hash_variable("character walk speed norm"),
            } },
            .next = &[_]eng.AnimationGraph.NodeTransition{
                .{
                    .node = 0,
                    .condition = .{ .Float = .{
                        .variable_id = eng.AnimationGraph.hash_variable("character speed"),
                        .comparison = .LessThan,
                        .value = 0.05,
                    } },
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
                .{
                    .node = 2,
                    .condition = .{ .Event = .{
                        .variable_id = eng.AnimationGraph.hash_variable("character attack"),
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
            .next = &[_]eng.AnimationGraph.NodeTransition{
                .{
                    .node = 0,
                    .condition = .Always,
                    .transition_duration = 0.1,
                    .transition_easing = es.Easing.OutLinear,
                },
            },
        },
    };

    return try eng.AnimationGraph.init(eng.get().general_allocator, anim_nodes[0..]);
}
