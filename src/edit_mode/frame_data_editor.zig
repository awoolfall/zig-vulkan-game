const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;

const StandardRenderer = @import("../render.zig");
const AnimationGraph = eng.animation.Graph;

const Self = @This();

camera: eng.camera.Camera,

model: ?eng.assets.ModelAssetId = null,

animation_model: ?eng.assets.ModelAssetId = null,
animation: ?eng.assets.AnimationAssetId = null,

animation_graph: AnimationGraph,
animation_control_data: AnimationGraph.ControlData,

pub fn deinit(self: *Self) void {
    self.animation_control_data.deinit();
    self.animation_graph.deinit();
}

pub fn init() !Self {
    return Self {
        .camera = eng.camera.Camera {
            .field_of_view_y = eng.camera.Camera.horizontal_to_vertical_fov(std.math.degreesToRadians(90.0), eng.get().gfx.swapchain_aspect()),
            .near_field = 0.3,
            .far_field = 10000.0,
            .move_speed = 10.0,
            .mouse_sensitivity = 0.001,
            .max_orbit_distance = 10.0,
            .min_orbit_distance = 1.0,
            .orbit_distance = 5.0,
        },
        .animation_graph = try AnimationGraph.init(eng.get().general_allocator, &.{
            AnimationGraph.Node {
                .next = &.{ AnimationGraph.NodeTransition {
                    .condition = .{ .Event = .{ .variable_id = AnimationGraph.hash_variable("transition"), } },
                    .node = 1,
                    .transition_duration = 0.5,
                } },
                .node = .{ .Basic = .{ .animation = undefined, } }
            },
            AnimationGraph.Node {
                .next = &.{ AnimationGraph.NodeTransition {
                    .condition = .{ .Event = .{ .variable_id = AnimationGraph.hash_variable("transition"), } },
                    .node = 0,
                    .transition_duration = 0.5,
                } },
                .node = .{ .Basic = .{ .animation = undefined, } }
            },
        }),
        .animation_control_data = .{
            .variable_map = .init(eng.get().general_allocator),
        },
    };
}

pub fn exit_mode(self: *Self) !void {
    _ = self;
}

pub fn enter_mode(self: *Self) !void {
    _ = self;
}

pub fn update_and_render(self: *Self, standard_renderer: *StandardRenderer) !void {
    const imui = &eng.get().imui;

    {
        const background_box = imui.push_floating_layout(.Y, 0.0, 0.0, .{@src()});
        defer imui.pop_layout();

        const entity_editor_background_position, _ = imui.get_widget_data([2]f32, background_box) catch unreachable;
        imui.set_floating_layout_position(background_box, entity_editor_background_position[0], entity_editor_background_position[1]);

        if (imui.get_widget(background_box)) |background_widget| {
            set_background_widget_layout(background_widget);

            // origin is top right
            background_widget.anchor = .{ 1.0, 0.0 };
            background_widget.pivot = .{ 1.0, 0.0 };
        }

        _ = eng.ui.widgets.label.create(imui, "Frame Data Editor");

        _ = eng.ui.widgets.label.create(imui, "Display Model:");
        const model_drop_zone = eng.ui.widgets.file_drop_zone.create(imui, .{@src()});
        model_drop_zone.id.get().semantic_size[1] = eng.ui.SemanticSize { .kind = .Pixels, .value = 25.0, };
        if (model_drop_zone.data_changed) blk: {
            std.debug.assert(eng.get().input.dropped_files.len != 0);
            const model_uri = try eng.util.uri.construct_uri_from_path(eng.get().frame_allocator, eng.get().input.dropped_files[0]);
            defer eng.get().frame_allocator.free(model_uri);

            self.model = eng.get().asset_manager.get_asset_id(model_uri) catch |err| {
                std.log.warn("Failed to get model asset: {s}: {}", .{model_uri, err});
                break :blk;
            };
        }

        _ = eng.ui.widgets.label.create(imui, "Animation Source:");
        var anim_drop_zone = eng.ui.widgets.file_drop_zone.create(imui, .{@src()});
        anim_drop_zone.id.get().semantic_size[1] = eng.ui.SemanticSize { .kind = .Pixels, .value = 25.0, };
        if (anim_drop_zone.data_changed) blk: {
            std.debug.assert(eng.get().input.dropped_files.len != 0);
            const model_uri = try eng.util.uri.construct_uri_from_path(eng.get().frame_allocator, eng.get().input.dropped_files[0]);
            defer eng.get().frame_allocator.free(model_uri);

            self.animation_model = eng.get().asset_manager.get_asset_id(model_uri) catch |err| {
                std.log.warn("Failed to get model asset: {s}: {}", .{model_uri, err});
                break :blk;
            };
        }

        var animation_combobox = eng.ui.widgets.combobox.create(imui, .{@src()});
        if (animation_combobox.init) {
            const cb_data, _ = try animation_combobox.id.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, imui);
            cb_data.default_text = try imui.widget_allocator().dupe(u8, "Select an animation");
            cb_data.can_be_default = true;
            cb_data.selected_index = null;
            if (self.animation_model) |_| {
                anim_drop_zone.data_changed = true;
            }
        }
        if (anim_drop_zone.data_changed) {
            const cb_data, _ = try animation_combobox.id.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, imui);
            cb_data.options.clearRetainingCapacity();
            const animation_model: *eng.assets.ModelAsset.BaseType = try eng.get().asset_manager.get_asset(eng.assets.ModelAsset, self.animation_model.?);
            for (animation_model.animations) |*anim| {
                try cb_data.options.append(imui.widget_allocator(), try imui.widget_allocator().dupe(u8, anim.name));
            }
            if (self.animation) |anim_id| {
                const animation: *eng.assets.AnimationAsset.BaseType = try eng.get().asset_manager.get_asset(eng.assets.AnimationAsset, anim_id);
                cb_data.selected_index = animation.animation_id;
            } else {
                cb_data.selected_index = 0;
            }
            cb_data.can_be_default = false;
            animation_combobox.data_changed = true;
        }
        if (animation_combobox.data_changed) {
            const cb_data, _ = try animation_combobox.id.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, imui);
            const animation_model_metadata: eng.assets.AssetManager.AssetMetadata = eng.get().asset_manager.asset_metadata.get(self.animation_model.?.unique_id) orelse return error.NoMetadata;
            const animation_uri = try std.fmt.allocPrint(eng.get().frame_allocator, "{s}/animations/{s}", .{animation_model_metadata.uri, cb_data.options.items[cb_data.selected_index.?]});
            const init_animation_graph = self.animation == null;
            self.animation = try eng.get().asset_manager.get_asset_id(animation_uri);
            if (init_animation_graph) {
                self.animation_graph.nodes.items[@mod(self.animation_control_data.active_node, 2)].node.Basic.animation = self.animation.?;
            }
            self.animation_graph.nodes.items[@mod(self.animation_control_data.active_node + 1, 2)].node.Basic.animation = self.animation.?;
            self.animation_graph.trigger_event("transition", &self.animation_control_data);
        }
    }

    if (self.animation) |_| {
        self.animation_graph.update(&self.animation_control_data);
    }

    if (self.model) |m| {
        _ = m;
        try self.push_model_for_rendering(standard_renderer);
    }

    self.camera.orbit_camera_update(zm.f32x4s(0.0), &eng.get().window, &eng.get().input, &eng.get().time);
}

fn set_background_widget_layout(background_widget: *eng.ui.Widget) void {
    background_widget.semantic_size[0].minimum_pixel_size = 400;
    background_widget.flags.clickable = true;
    background_widget.flags.render = true;
    background_widget.flags.hover_effect = false;
    background_widget.border_width_px = .all(3);
    background_widget.padding_px = .all(10);
    background_widget.corner_radii_px = .all(10);
    background_widget.children_gap = 5;
}

fn push_model_for_rendering(
    self: *Self,
    standard_renderer: *StandardRenderer
) !void {
    const engine = eng.get();

    const m = engine.asset_manager.get_asset(eng.assets.ModelAsset, self.model orelse return) catch unreachable;

    const pose = try eng.get().frame_allocator.alloc(zm.Mat, eng.mesh.MAX_BONES);
    defer eng.get().frame_allocator.free(pose);
    @memset(pose, zm.identity());

    const bone_info = blk: {
        if (self.animation) |animation_id| {
            _ = animation_id;
            self.animation_graph.calculate_bone_transforms(eng.get().general_allocator, m, &self.animation_control_data, pose);
            const bone_index_info = standard_renderer.push_bones(pose[0..]) catch unreachable;
            break :blk StandardRenderer.AnimatedRenderObject.BoneInfo {
                .bone_offset = bone_index_info.start_idx,
                .bone_count = bone_index_info.end_idx - bone_index_info.start_idx,
            };
        }
        break :blk null;
    };

    // Finally, render the model
    render_model(
        standard_renderer,
        m,
        if (bone_info) |bi| 
        .{
            .pose_data = pose,
            .bone_info = bi,
        }
        else null,
        .{}
    ) catch unreachable;
}

fn render_model(
    standard_renderer: *StandardRenderer,
    model: *const eng.mesh.Model,
    bones_data: ?struct {
        pose_data: []const zm.Mat,
        bone_info: StandardRenderer.AnimatedRenderObject.BoneInfo,
    },
    transform: eng.Transform,
) !void {
    const __tracy_zone = eng.ztracy.ZoneN(@src(), "render model");
    defer __tracy_zone.End();

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
            const ___tracy_zone = eng.ztracy.ZoneN(@src(), "apply pose");
            defer ___tracy_zone.End();
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
                    .entity_id = 1,
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
                    standard_renderer.push_animated(.{
                        .standard = render_object,
                        .bone_info = bd.bone_info,
                    }) catch unreachable;
                } else {
                    standard_renderer.push(render_object)
                        catch unreachable;
                }
            }
        }

        node_matrix_list[node_index] = node_model_matrix;
    }
}
