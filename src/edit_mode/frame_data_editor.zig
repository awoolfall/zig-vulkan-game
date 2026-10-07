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

physics_shape_keys: std.ArrayList(PhysicsShapeChannel),

const PhysicsShapeChannel = struct {
    keys: std.ArrayList(PhysicsShapeKey),
};

const PhysicsShapeKey = struct {
    time: f32,
};

pub fn deinit(self: *Self) void {
    const alloc = eng.get().general_allocator;
    for (self.physics_shape_keys.items) |*channel| {
        channel.keys.deinit(alloc);
    }
    self.physics_shape_keys.deinit(alloc);
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
                .next = &.{},
                .node = .{ .Basic = .{ .animation = undefined, } }
            },
        }),
        .animation_control_data = .{
            .variable_map = .init(eng.get().general_allocator),
        },
        .physics_shape_keys = .{},
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
            self.animation = try eng.get().asset_manager.get_asset_id(animation_uri);
            self.animation_graph.nodes.items[0].node.Basic.animation = self.animation.?;
        }

        const add_physics_shape = eng.ui.widgets.badge.create(imui, "add physics shape", .{@src()});
        if (add_physics_shape.clicked) {
        }
    }

    {
        const bottom_bar = imui.push_layout(.Y, .{@src()});
        defer imui.pop_layout();
        bottom_bar.get().semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, };
        bottom_bar.get().semantic_size[1] = .{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = false, };
        bottom_bar.get().pivot = .{ 0.5, 1.0 };
        bottom_bar.get().anchor = .{ 0.5, 1.0 };
        bottom_bar.get().flags.render = true;

        _ = eng.ui.widgets.label.create(imui, "Hello bottom bar");
        const animation_duration_s, const animation_duration_ticks = blk: {
            const animation_id = self.animation orelse break :blk .{ 0.0, 1 };
            const animation_ptr: *eng.assets.AnimationAsset.BaseType = eng.get().asset_manager.get_asset(eng.assets.AnimationAsset, animation_id) catch break :blk .{ 0.0, 1 };
            const animation = animation_ptr.get() catch break :blk .{ 0.0, 1 };
            break :blk .{ animation.duration_seconds, animation.duration_ticks };
        };
        _ = animation_duration_ticks;
        var progress = @mod(self.animation_control_data.active_time / animation_duration_s, 1.0);
        const progress_slider = eng.ui.widgets.slider.create(imui, &progress , .{
            .min = 0.0,
            .max = 1.0,
            //.step = 1.0 / @as(f32, @floatFromInt(animation_duration_ticks)),
            .step = 0.01,
        }, .{@src()});
        progress_slider.id.background_bar.get().pivot = .{ 0.5, 0.5 };
        progress_slider.id.background_bar.get().anchor = .{ 0.5, 0.5 };
        progress_slider.id.background_bar.get().semantic_size[0].value = 0.5;

        if (progress_slider.data_changed) {
            self.animation_control_data.active_time = progress * animation_duration_s;
        }
    }

    if (self.animation) |_| {
        self.animation_graph.update(&self.animation_control_data);
    }

    if (self.model) |m| {
        standard_renderer.push_model(.{
            .model = m,
            .animation_data = .{
                .animation_graph = &self.animation_graph,
                .control_data = &self.animation_control_data,
            },
            .transform = .{},
        }) catch |err| {
            std.log.warn("Unable to push model for rendering: {}", .{err});
        };
    }

    self.camera.orbit_camera_update(zm.f32x4s(0.0), &eng.get().os, &eng.get().input, &eng.get().time);
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
