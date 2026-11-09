const std = @import("std");
const eng = @import("self");
const scene_util = @import("engine/scene_util.zig");

const Self = @This();

mode: enum {
    Editing,
    Playing,
},

saved_state: ?struct {
    arena: std.heap.ArenaAllocator,
    scene: std.json.Value,
    entities: []const scene_util.SerializedEntity,
},

default_camera: eng.Camera,

pub fn deinit(self: *Self) void {
    if (self.saved_state) |saved_state| {
        saved_state.arena.deinit();
        self.saved_state = null;
    }
}

pub fn init() !Self {
    return Self{
        .mode = .Editing,
        .saved_state = null,
        .default_camera = .{
            .field_of_view_y = eng.Camera.horizontal_to_vertical_fov(std.math.degreesToRadians(90.0), eng.get().gfx.swapchain_aspect()),
            .near_field = 0.3,
            .far_field = 10000.0,
            .move_speed = 10.0,
            .mouse_sensitivity = 0.001,
            .max_orbit_distance = 10.0,
            .min_orbit_distance = 1.0,
            .orbit_distance = 0.0,
        },
    };
}

pub fn update(self: *Self) !void {
    if (eng.get().input.get_key_up(eng.input.KeyCode.F1)) {
        try self.swap_mode();
    }

    switch (self.mode) {
        .Editing => try self.editing_update(),
        .Playing => {
            const app_update_result = eng.get().app_interface.fn_update();
            if (app_update_result != 0) {
                std.log.err("App Update error, returning to editor: {}", .{app_update_result});
                try self.swap_mode();
            }
        },
    }
}

fn swap_mode(self: *Self) !void {
    switch (self.mode) {
        .Editing => {
            var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
            errdefer arena.deinit();

            const serialized_scene = try scene_util.serialize_scene(&arena, &eng.get().ecs, "saved");
            const serialized_entities = try scene_util.serialize_entities(&arena, &eng.get().ecs);

            self.saved_state = .{
                .arena = arena,
                .scene = serialized_scene,
                .entities = serialized_entities,
            };

            self.mode = .Playing;
        },
        .Playing => {
            if (self.saved_state) |saved_state| {
                eng.get().ecs.clear_entities();
                scene_util.load_scene_into_ecs(&eng.get().ecs, &saved_state.scene);
                scene_util.load_serialized_entities_into_ecs(&eng.get().ecs, saved_state.entities);
                saved_state.arena.deinit();
                self.saved_state = null;
            }

            self.mode = .Editing;
        },
    }
}

fn editing_update(self: *Self) !void {
    self.default_camera.fly_camera_update(&eng.get().os, &eng.get().input, &eng.get().time);

    const imui = eng.get().ecs.get_resource(eng.Imui) orelse return error.ImuiResourceDoesNotExist;

    {
        const top_bar_background = imui.push_layout(.X, .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(top_bar_background)) |top_widget| {
            top_widget.layout_axis = null;
            top_widget.semantic_size[0].kind = .ParentPercentage;
            top_widget.semantic_size[0].value = 1.0;
            top_widget.semantic_size = .{
                .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false },
                .{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = false },
            };
            top_widget.padding_px = .{ .left = 10, .right = 10, .top = 0, .bottom = 0 };
            top_widget.children_gap = 5;
            top_widget.flags.render = true;
            top_widget.background_colour = imui.palette().background;
            top_widget.background_colour.?[3] = 0.5;
        }

        const l = eng.Imui.widgets.label.create(imui, try std.fmt.allocPrint(
            eng.get().frame_allocator,
            "Edit Mode{s}",
            .{
                "", //if (self.loaded_scene_name) |scene_name| try std.fmt.allocPrint(eng.get().frame_allocator, ": {s}", .{scene_name}) else "",
            },
        ));
        if (imui.get_widget(l.id)) |label_widget| {
            label_widget.anchor = .{ 0.5, 0.5 };
            label_widget.pivot = .{ 0.5, 0.5 };
        }
    }

    // temporary button bind to load "scene"
    if (eng.get().input.get_key_up(eng.input.KeyCode.F2)) {
        // remove all entities (and components)
        eng.get().ecs.clear_entities();

        // Create new entities and set scene name
        var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
        defer arena.deinit();

        const serialized_entities = try scene_util.read_serialized_entites_from_filesystem(&arena, "scene");
        const serialized_scene = try scene_util.read_scene_file_from_filesystem(&arena, "scene");

        scene_util.load_scene_into_ecs(&eng.get().ecs, &serialized_scene);
        scene_util.load_serialized_entities_into_ecs(&eng.get().ecs, serialized_entities);
    }

    // temporary button bind to save "scene"
    if (eng.get().input.get_key_up(eng.input.KeyCode.F3)) {
        var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
        defer arena.deinit();

        const scene_entities = try scene_util.serialize_entities(&arena, &eng.get().ecs);
        const scene = try scene_util.serialize_scene(&arena, &eng.get().ecs, "scene");
        try scene_util.save_scene_to_filesystem("scene", scene, scene_entities);

        std.log.debug("saved scene {s}!", .{"scene"});
    }

    {
        const background = imui.push_floating_layout(.Y, 500.0, 500.0, .{@src()});
        defer imui.pop_layout();

        background.get().flags.render = true;
        background.get().semantic_size[@intFromEnum(eng.Imui.Axis.X)].minimum_pixel_size = 300.0;
        background.get().padding_px = .all(5.0);
        background.get().children_gap = 5.0;

        _ = eng.Imui.widgets.label.create(imui, "Resources:");

        var resource_iter = eng.get().ecs.resources.iterator();

        var items: std.ArrayList([]const u8) = .empty;
        defer items.deinit(eng.get().frame_allocator);

        while (resource_iter.next()) |pair| {
            try items.append(eng.get().frame_allocator, pair.value_ptr.name);
        }

        _ = create_item_search_widget(imui, items.items, .{@src()});

        resource_iter = eng.get().ecs.resources.iterator();
        while (resource_iter.next()) |pair| {
            if (pair.value_ptr.data) |resource| {
                const collapsable = eng.Imui.widgets.collapsible.create(imui, pair.value_ptr.name, .{ pair.key_ptr.*, @src() });
                if (try eng.Imui.widgets.collapsible.collapsible_is_open(imui, collapsable.id)) {
                    const resource_box = imui.push_layout(.Y, .{ pair.key_ptr.*, @src() });
                    defer imui.pop_layout();

                    resource_box.get().margin_px = .all(5.0);
                    resource_box.get().padding_px.left = 10.0;
                    resource_box.get().margin_px.left = 10.0;
                    resource_box.get().border_width_px.left = 2.0;
                    resource_box.get().children_gap = 5.0;
                    resource_box.get().flags.render = true;

                    if (!pair.value_ptr.functions.fn_editor_ui(imui, resource)) {
                        _ = eng.Imui.widgets.label.create(imui, "Not implemented");
                    }
                }
            }
        }
    }
}

const ItemSearchData = struct {
    options: std.ArrayList([]u8),
    dropdown_is_open: bool = false,

    pub fn deinit(self: *ItemSearchData, alloc: std.mem.Allocator) void {
        for (self.options.items) |o| {
            alloc.free(o);
        }
        self.options.deinit(alloc);
    }

    pub fn init(alloc: std.mem.Allocator) !ItemSearchData {
        _ = alloc;
        return ItemSearchData{
            .options = .empty,
        };
    }

    pub fn clone(self: *ItemSearchData, alloc: std.mem.Allocator) !ItemSearchData {
        var new_options = std.ArrayList([]u8).empty;
        errdefer new_options.deinit(alloc);

        for (self.options.items) |o| {
            try new_options.append(alloc, try alloc.dupe(u8, o));
        }

        return ItemSearchData{
            .options = new_options,
            .dropdown_is_open = self.dropdown_is_open,
        };
    }
};

fn create_item_search_widget(imui: *eng.Imui, items: []const []const u8, key: anytype) eng.Imui.WidgetSignal(eng.Imui.widgets.line_edit.TextInputId) {
    const add_layout = imui.push_layout(.X, .{@src()});
    defer imui.pop_layout();

    add_layout.get().children_gap = 2.0;

    const data, const data_state = add_layout.get_widget_data(ItemSearchData, imui) catch unreachable;

    if (data_state == .Init) {
        for (items) |item| {
            data.options.append(imui.widget_allocator(), imui.widget_allocator().dupe(u8, item) catch unreachable) catch unreachable;
        }
    }

    var component_search_line_edit = eng.Imui.widgets.line_edit.create(imui, .{}, key ++ .{@src()});
    const line_edit_data, _ = component_search_line_edit.id.box.get_widget_data(eng.Imui.widgets.line_edit.TextInputState, imui) catch unreachable;

    if (imui.focus_item) |focus_item| {
        data.dropdown_is_open = (focus_item == component_search_line_edit.id.box.get().key or
            focus_item == component_search_line_edit.id.text.get().key);
    } else {
        data.dropdown_is_open = false;
    }

    // if the dropdown should be shown then render it
    dropdown_is_open: {
        if (data.dropdown_is_open) {
            // determine the position of the dropdown options based on the primary combobox rect
            const dropdown_pos = if (imui.get_widget_from_last_frame(component_search_line_edit.id.box)) |b|
                .{ b.rect().left, b.rect().bottom + 4 }
            else
                break :dropdown_is_open;

            // push the options background layout
            const options_background = imui.push_priority_floating_layout(.Y, dropdown_pos[0], dropdown_pos[1], key ++ .{@src()});
            defer imui.pop_layout();

            if (imui.get_widget(options_background)) |options_background_widget| {
                options_background_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true };
                options_background_widget.semantic_size[1] = .{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = true };

                options_background_widget.flags.render = true;
                options_background_widget.border_width_px = .all(1);
                options_background_widget.padding_px = .all(4);
                options_background_widget.children_gap = 2;
                options_background_widget.corner_radii_px = .all(4);
            }

            // push each of the options into the dropdown menu
            const lower_line_edit_text = std.ascii.allocLowerString(eng.get().frame_allocator, line_edit_data.text.items) catch unreachable;
            defer eng.get().frame_allocator.free(lower_line_edit_text);

            var is_first_item = true;
            for (data.options.items, 0..) |option, i| {
                const lower_option = std.ascii.allocLowerString(eng.get().frame_allocator, option) catch unreachable;
                defer eng.get().frame_allocator.free(lower_option);

                //if (fuzzy_distance(option, line_edit_data.text.items) < 0.7) { continue; }
                if (lower_line_edit_text.len > 0) {
                    if (std.mem.count(u8, lower_option, lower_line_edit_text) == 0) {
                        continue;
                    }
                }

                const option_background = imui.push_layout(.X, key ++ .{ @src(), i });
                defer imui.pop_layout();

                // give the option a hover effect
                if (imui.get_widget(option_background)) |option_background_widget| {
                    option_background_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true };
                    option_background_widget.flags.clickable = true;
                    option_background_widget.flags.render = true;
                    option_background_widget.padding_px = .all(4);
                    option_background_widget.corner_radii_px = .all(4);
                }

                // if the option is clicked then set text field
                if (imui.generate_widget_signals(option_background).clicked) {
                    line_edit_data.text.clearRetainingCapacity();
                    line_edit_data.text.appendSlice(imui.widget_allocator(), option) catch unreachable;
                    component_search_line_edit.data_changed = true;
                }

                // if enter is clicked then set the text field to the first item
                if (eng.get().input.get_key_down(eng.input.KeyCode.Enter)) {
                    if (is_first_item) {
                        line_edit_data.text.clearRetainingCapacity();
                        line_edit_data.text.appendSlice(imui.widget_allocator(), option) catch unreachable;
                        imui.focus_item = null;
                        component_search_line_edit.data_changed = true;
                    }
                }

                _ = eng.Imui.widgets.label.create(imui, option);
                is_first_item = false;
            }
        }
    }

    return component_search_line_edit;
}
