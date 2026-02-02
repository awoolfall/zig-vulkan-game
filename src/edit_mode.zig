const Self = @This();
const std = @import("std");

const eng = @import("engine");
const gfx = eng.gfx;

const Gizmo = @import("gizmo/gizmo.zig");
const st = @import("selection_textures.zig");
const pe = @import("particle_editor.zig");
const StandardRenderer = @import("render.zig");
const Terrain = @import("terrain/terrain.zig");
const TerrainRenderer = @import("terrain/terrain_renderer.zig");
const Ocean = @import("ocean/ocean.zig");

const zm = eng.zmath;
const sr = eng.serialize;
const assets = eng.assets;
const KeyCode = eng.input.KeyCode;
const Transform = eng.Transform;
const Camera = eng.camera.Camera;
const Imui = eng.ui;
const GenerationalIndex = eng.gen.GenerationalIndex;
const SelectionOutlineRenderer = @import("edit_mode/selection_outline.zig");

const entity_components = @import("entity.zig");

const EditorMode = enum {
    SceneEditor,
};

editor_camera: Camera,
gizmo: Gizmo,
selection_outline_renderer: SelectionOutlineRenderer,

selected_entity: ?eng.ecs.Entity = null,
render_only_selected_entity: bool = false,

file_dropdown_open: bool = false,
edit_dropdown_open: bool = false,

edit_ocean_params_open: bool = false,

loaded_scene_name: ?[]u8 = null,

load_scene_popup_data: LoadScenePopup,
load_scene_popup_is_open: bool = false,

pub fn deinit(self: *Self) void {
    self.load_scene_popup_data.deinit();
    self.set_loaded_scene_name(null) catch unreachable;
    self.gizmo.deinit();
    self.selection_outline_renderer.deinit();
}

pub fn init(standard_renderer: *const StandardRenderer) !Self {
    var gizmo = try Gizmo.init(eng.get().general_allocator);
    errdefer gizmo.deinit();

    var selection_outline_renderer = try SelectionOutlineRenderer.init(eng.get().general_allocator, standard_renderer.selection_textures.image);
    errdefer selection_outline_renderer.deinit();

    return Self {
        .gizmo = gizmo,
        .selection_outline_renderer = selection_outline_renderer,
        .load_scene_popup_data = try LoadScenePopup.init(),
        .editor_camera = Camera {
            .field_of_view_y = Camera.horizontal_to_vertical_fov(std.math.degreesToRadians(90.0), eng.get().gfx.swapchain_aspect()),
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

fn set_loaded_scene_name(self: *Self, name: ?[]const u8) !void {
    if (self.loaded_scene_name) |old_name| {
        eng.get().general_allocator.free(old_name);
    }
    self.loaded_scene_name = if (name) |n| try eng.get().general_allocator.dupe(u8, n) else null;
}

pub fn update(self: *Self, selection_textures: *st.SelectionTextures(u32), terrain_renderer: *TerrainRenderer, ocean: *Ocean) !void {
    if (!eng.get().imui.has_focus()) {
        self.editor_camera.fly_camera_update(&eng.get().window, &eng.get().input, &eng.get().time);

        // focus camera on selected entity
        if (eng.get().input.get_key_down(KeyCode.F)) blk: {
            if (self.selected_entity) |si| {
                const selected_entity_transform = eng.get().ecs.get_component(eng.entity.TransformComponent, si) orelse break :blk;

                self.editor_camera.transform.position = 
                    selected_entity_transform.transform.position -
                    (self.editor_camera.transform.forward_direction() * zm.f32x4s(10.0));
            }
        }

        self.render_only_selected_entity = eng.get().input.get_key(KeyCode.G);

        // new entity button
        if (eng.get().input.get_key_down(KeyCode.E)) {
            self.create_new_entity() catch |err| {
                std.log.warn("Unable to create new entity: {}", .{err});
            };
        }

        // delete entity button
        if (eng.get().input.get_key_down(KeyCode.Delete)) {
            self.remove_selected_entity();
        }

        var interaction_available = true;

        if (interaction_available) {
            if (self.selected_entity) |selected_entity| blk: {
                const entity_transform = eng.get().ecs.get_component(eng.entity.TransformComponent, selected_entity) orelse break :blk;
                if (self.gizmo.update(&entity_transform.transform)) {
                    interaction_available = false;
                }
            }
        }

        if (interaction_available) {
            if (self.selected_entity) |selected_entity| blk: {
                const entity_terrain = eng.get().ecs.get_component(entity_components.TerrainComponent, selected_entity) orelse break :blk;

                const modified = entity_terrain.terrain.edit_terrain(terrain_renderer) catch |err| {
                    std.log.err("Failed to edit terrain: {}", .{err});
                    break :blk;
                };
                if (modified) {
                    interaction_available = false;
                }
            }
        }

        // Select entity
        if (interaction_available and eng.get().input.get_key_down(KeyCode.MouseLeft)) {
            interaction_available = false;
            const selection_entity_id = selection_textures.get_value_at_position(@intCast(eng.get().input.cursor_position[0]), @intCast(eng.get().input.cursor_position[1])) catch |err| {
                std.log.err("cannot get value at position: {}", .{err});
                return;
            };

            if (selection_entity_id == 0) {
                self.selected_entity = null;
            } else if (self.selected_entity != null and self.selected_entity.?.idx.index == selection_entity_id) {
                self.selected_entity = null;
            } else {
                if (selection_entity_id < eng.get().ecs.entity_data.data.items.len) {
                    const entity_item = eng.get().ecs.entity_data.data.items[selection_entity_id];
                    const entity = eng.ecs.Entity { .idx = .{ .index = selection_entity_id, .generation = entity_item.generation, } };
                    if (entity_item.item_data) |_| {
                        const entity_name = eng.get().ecs.get_entity_name(entity) orelse "unnamed";
                        std.log.info("selected new entity with name: {s}", .{entity_name});

                        self.selected_entity = entity;
                    } else {
                        std.log.info("entity not found!", .{});
                    }
                } else {
                    std.log.warn("Attempted to set invalid index as the selected entity", .{});
                }
            }
        }
    }

    const imui = &eng.get().imui;

    self.entity_editor_ui(.{self.selected_entity, @src()});

    if (self.edit_ocean_params_open) {
        ocean_edit_ui(self, imui, ocean, .{@src()});
    }

    try self.top_bar_ui(.{@src()});

    if (self.load_scene_popup_is_open) {
        const background_layout = imui.push_floating_layout(.X, 300.0, 300.0, .{@src()});
        defer imui.pop_layout();
        if (imui.get_widget(background_layout)) |bg| {
            set_background_widget_layout(bg);
        }

        self.load_scene_popup(&self.load_scene_popup_data, .{@src()})
            catch unreachable;
    }
}

fn top_bar_ui(self: *Self, key: anytype) !void {
    const imui = &eng.get().imui;

    const top_bar_background = imui.push_layout(.X, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(top_bar_background)) |top_widget| {
        top_widget.layout_axis = null;
        top_widget.semantic_size[0].kind = .ParentPercentage;
        top_widget.semantic_size[0].value = 1.0;
        top_widget.semantic_size = .{
            .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, },
            .{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = false, },
        };
        top_widget.padding_px = .{
            .left = 10,
            .right = 10,
            .top = 0,
            .bottom = 0,
        };
        top_widget.children_gap = 5;
        top_widget.flags.render = true;
        top_widget.background_colour = imui.palette().background;
        top_widget.background_colour.?[3] = 0.5;
    }

    const l = Imui.widgets.label.create(imui, try std.fmt.allocPrint(eng.get().frame_allocator, "Edit Mode{s}", .{
        if (self.loaded_scene_name) |scene_name|
            try std.fmt.allocPrint(eng.get().frame_allocator, ": {s}", .{scene_name})
         else ""
    }));
    if (imui.get_widget(l.id)) |label_widget| {
        label_widget.anchor = .{ 0.5, 0.5 };
        label_widget.pivot = .{ 0.5, 0.5 };
    }

    const items_layout = imui.push_layout(.X, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(items_layout)) |ilw| {
        ilw.children_gap = 4;
    }

    {
        const file_button = Imui.widgets.button.create(imui, "File", key ++ .{@src()});
        if (imui.get_widget(file_button.id.box)) |file_widget| {
            file_widget.background_colour = zm.f32x4s(0.0);
            file_widget.border_width_px = .{};
            file_widget.padding_px = .lr_tb(10, 5);
        }
        if (file_button.clicked) {
            self.file_dropdown_open = !self.file_dropdown_open;
        }
        defer {
            if (!file_button.clicked) {
                if (eng.get().input.get_key_down(KeyCode.MouseLeft)) {
                    self.file_dropdown_open = false;
                }
            }
        }

        file_blk: {
            if (self.file_dropdown_open) {
                const file_lfw = imui.get_widget_from_last_frame(file_button.id.box) orelse break :file_blk;
                const file_lfw_rect = file_lfw.rect();
                const file_dropdown = imui.push_priority_floating_layout(.Y, file_lfw_rect.left, file_lfw_rect.bottom, key ++ .{@src()});
                if (imui.get_widget(file_dropdown)) |file_dropdown_widget| {
                    file_dropdown_widget.flags.render = true;
                }
                defer imui.pop_layout();

                const save_button = Imui.widgets.badge.create(imui, "Save Scene", key ++ .{@src()});
                if (save_button.clicked) {
                    if (self.loaded_scene_name) |scene_name| {
                        save_entities_to_scene(scene_name) catch |err| {
                            std.log.err("Failed to save scene: {}", .{err});
                        };
                        std.log.debug("saved scene {s}!", .{scene_name});
                    }
                }
                const load_button = Imui.widgets.badge.create(imui, "Load Scene", key ++ .{@src()});
                if (load_button.clicked) {
                    self.load_scene_popup_is_open = true;
                    // for (eng.get().entities.list.data.items, 0..) |*it, idx| {
                    //     if (it.item_data) |_| {
                    //         eng.get().entities.remove_entity(GenerationalIndex{.index = idx, .generation = it.generation}) catch unreachable;
                    //     }
                    // }
                    // create_scene_entities("scene") catch |err| {
                    //     std.log.err("Failed to load scene: {}", .{err});
                    // };
                    // std.log.debug("loaded!", .{});
                }
            }
        }
    }

    {
        const edit_button = Imui.widgets.button.create(imui, "Edit", key ++ .{@src()});
        if (imui.get_widget(edit_button.id.box)) |edit_widget| {
            edit_widget.background_colour = zm.f32x4s(0.0);
            edit_widget.border_width_px = .{};
            edit_widget.padding_px = .lr_tb(10, 5);
        }
        if (edit_button.clicked) {
            self.edit_dropdown_open = !self.edit_dropdown_open;
        }
        defer {
            if (!edit_button.clicked) {
                if (eng.get().input.get_key_down(KeyCode.MouseLeft)) {
                    self.edit_dropdown_open = false;
                }
            }
        }

        edit_blk: {
            if (self.edit_dropdown_open) {
                const edit_lfw = imui.get_widget_from_last_frame(edit_button.id.box) orelse break :edit_blk;
                const edit_lfw_rect = edit_lfw.rect();
                const edit_dropdown = imui.push_priority_floating_layout(.Y, edit_lfw_rect.left, edit_lfw_rect.bottom, key ++ .{@src()});
                if (imui.get_widget(edit_dropdown)) |edit_dropdown_widget| {
                    edit_dropdown_widget.flags.render = true;
                }
                defer imui.pop_layout();

                const new_button = Imui.widgets.badge.create(imui, "New Entity", key ++ .{@src()});
                if (new_button.clicked) {
                    self.create_new_entity() catch |err| {
                        std.log.err("Failed to create new entity: {}", .{err});
                    };
                }

                const delete_button = Imui.widgets.badge.create(imui, "Delete Entity", key ++ .{@src()});
                if (delete_button.clicked) {
                    self.remove_selected_entity();
                }

                const duplicate_button = Imui.widgets.badge.create(imui, "Duplicate Entity", key ++ .{@src()});
                if (duplicate_button.clicked) {
                    self.duplicate_selected_entity() catch |err| {
                        std.log.err("Failed to duplicate entity: {}", .{err});
                    };
                }

                const edit_ocean_button = Imui.widgets.badge.create(imui, "Edit Ocean Parameters", key ++ .{@src()});
                if (edit_ocean_button.clicked) {
                    self.edit_ocean_params_open = true;
                }
            }
        }
    }
}

pub fn render_cmd(self: *Self, cmd: *gfx.CommandBuffer) void {
    if (self.selected_entity) |selected_entity| {
        blk: {
            const transform_component = eng.get().ecs.get_component(eng.entity.TransformComponent, selected_entity) orelse break :blk;
            self.gizmo.render_cmd(cmd, &transform_component.transform, &self.editor_camera) catch |err| {
                std.log.warn("Unable to render edit mode gizmo: {}", .{err});
            };
        }

        self.selection_outline_renderer.render(cmd, @intCast(selected_entity.idx.index)) catch |err| {
            std.log.warn("Unable to render selection outline: {}", .{err});
        };
    }
}

fn create_new_entity(self: *Self) !void {
    const entity_id = eng.get().ecs.create_new_entity() catch |err| {
        std.log.err("Unable to create new entity: {}", .{err});
        return err;
    };
    errdefer eng.get().ecs.remove_entity(entity_id);

    const serialize_component = try eng.get().ecs.add_component(eng.entity.SerializationComponent, entity_id);
    serialize_component.serialize_id = null;

    const transform_component = try eng.get().ecs.add_component(eng.entity.TransformComponent, entity_id);
    transform_component.transform = .{
        .position = self.editor_camera.transform.position + zm.normalize3(self.editor_camera.transform.forward_direction()),
    };
}

fn duplicate_selected_entity(self: *Self) !void {
    if (self.selected_entity) |selected_entity_id| {
        var arena = std.heap.ArenaAllocator.init(eng.get().frame_allocator);
        defer arena.deinit();

        const serialized_entity = try eng.get().ecs.serialize_entity(arena.allocator(), selected_entity_id);

        const new_entity = try eng.get().ecs.deserialize_to_entity(serialized_entity);
        errdefer eng.get().ecs.remove_entity(new_entity);

        // clear the serialize id so that it will be generated on the next save
        const entity_serialize_component = try eng.get().ecs.add_component(eng.entity.SerializationComponent, new_entity);
        entity_serialize_component.serialize_id = null;

        self.selected_entity = new_entity;
    }
}

fn remove_selected_entity(self: *Self) void {
    if (self.selected_entity) |selected_entity| {
        eng.get().ecs.remove_entity(selected_entity);
        self.selected_entity = null;
    }
}

fn set_background_widget_layout(background_widget: *Imui.Widget) void {
    background_widget.semantic_size[0].minimum_pixel_size = 400;
    background_widget.flags.clickable = true;
    background_widget.flags.render = true;
    background_widget.flags.hover_effect = false;
    background_widget.border_width_px = .all(3);
    background_widget.padding_px = .all(10);
    background_widget.corner_radii_px = .all(10);
    background_widget.children_gap = 5;
}

const PhysicsData = struct {
    settings: eng.entity.PhysicsSettings,

    pub fn deinit(self: *PhysicsData, alloc: std.mem.Allocator) void {
        _ = self;
        _ = alloc;
    }

    pub fn init(alloc: std.mem.Allocator) !PhysicsData {
        _ = alloc;
        return PhysicsData { .settings = .{ .None = {} } };
    }

    pub fn clone(self: *PhysicsData, alloc: std.mem.Allocator) !PhysicsData {
        _ = alloc;
        return self.*;
    }
};

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
        return ItemSearchData {
            .options = .empty,
        };
    }

    pub fn clone(self: *ItemSearchData, alloc: std.mem.Allocator) !ItemSearchData {
        var new_options = std.ArrayList([]u8).empty;
        errdefer new_options.deinit(alloc);

        for (self.options.items) |o| {
            try new_options.append(alloc, try alloc.dupe(u8, o));
        }

        return ItemSearchData {
            .options = new_options,
            .dropdown_is_open = self.dropdown_is_open,
        };
    }
};

const EntityEditorTabWidth = 10;
fn entity_editor_ui(
    self: *Self,
    key: anytype,
) void {
    const imui = &eng.get().imui;

    const entity = self.selected_entity orelse return;

    const background_box = imui.push_floating_layout(.Y, 0.0, 0.0, key ++ .{@src()});
    defer imui.pop_layout();

    const entity_editor_background_position, _ = imui.get_widget_data([2]f32, background_box) catch unreachable;
    imui.set_floating_layout_position(background_box, entity_editor_background_position[0], entity_editor_background_position[1]);

    if (imui.get_widget(background_box)) |background_widget| {
        set_background_widget_layout(background_widget);

        // origin is top right
        background_widget.anchor = .{ 1.0, 0.0 };
        background_widget.pivot = .{ 1.0, 0.0 };
    }

    const form_label_size = Imui.SemanticSize {
        .kind = .ParentPercentage, .value = 0.3, .shrinkable = false,
    };

    const entity_editor_background_signals = imui.generate_widget_signals(background_box);
    if (entity_editor_background_signals.init) {
        entity_editor_background_position.* = .{ -10.0, 35.0 };
    }
    if (entity_editor_background_signals.dragged) {
        entity_editor_background_position[0] += eng.get().input.mouse_delta[0];
        entity_editor_background_position[1] += eng.get().input.mouse_delta[1];
    }

    const entity_editor_title_text = Imui.widgets.label.create(imui, "Entity Editor");
    if (imui.get_widget(entity_editor_title_text.id)) |entity_editor_title_widget| {
        entity_editor_title_widget.anchor = .{ 0.5, 0.5 };
        entity_editor_title_widget.pivot = .{ 0.5, 0.5 };
    }

    {
        const ll = imui.push_layout(.X, key ++ .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        const labell = Imui.widgets.label.create(imui, "name:");
        if (imui.get_widget(labell.id)) |label_widget| {
            label_widget.semantic_size[0] = form_label_size;
        }
        const name_edit = Imui.widgets.line_edit.create(imui, .{}, key ++ .{@src()});
        // if name line edit has changed then update the entity's name
        if (name_edit.init) {
            const name_edit_data, _ = imui.get_widget_data(Imui.widgets.line_edit.TextInputState, name_edit.id.box) catch unreachable;
            name_edit_data.text.appendSlice(imui.widget_allocator(), eng.get().ecs.get_entity_name(entity) orelse "unnamed") catch unreachable;
            name_edit_data.cursor = name_edit_data.text.items.len;
            name_edit_data.mark = name_edit_data.text.items.len;
        }
        if (name_edit.data_changed) {
            const name_edit_data, _ = imui.get_widget_data(Imui.widgets.line_edit.TextInputState, name_edit.id.box) catch unreachable;
            eng.get().ecs.set_entity_name(entity, name_edit_data.text.items) catch |err| {
                std.log.warn("Failed to set entity name: {}", .{err});
            };
        }
    }

    const ecs_component_info = @typeInfo(@TypeOf(eng.AppEcsSystem.ComponentTypes));

    {
        const component_add_layout = imui.push_layout(.X, key ++ .{@src()});
        defer imui.pop_layout();
        {
            const w = component_add_layout.get();
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, };
            w.children_gap = 2.0;
        }

        const data, const data_state = component_add_layout.get_widget_data(ItemSearchData, imui) catch unreachable;

        if (data_state == .Init) {
            inline for (ecs_component_info.@"struct".fields, 0..) |_, idx| {
                const option_text = imui.widget_allocator().dupe(u8, @typeName(eng.AppEcsSystem.ComponentTypes[idx])) catch unreachable;
                errdefer imui.widget_allocator().free(option_text);

                data.options.append(imui.widget_allocator(), option_text) catch unreachable;
            }
        }

        const component_search_line_edit = eng.ui.widgets.line_edit.create(imui, .{}, key ++ .{@src()});
        const line_edit_data, _ = component_search_line_edit.id.box.get_widget_data(eng.ui.widgets.line_edit.TextInputState, imui) catch unreachable;
        {
            const w = component_search_line_edit.id.box.get();
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, };
        }

        if (imui.focus_item) |focus_item| {
            data.dropdown_is_open = (
                focus_item == component_search_line_edit.id.box.get().key or
                focus_item == component_search_line_edit.id.text.get().key
            );
        } else {
            data.dropdown_is_open = false;
        }

        const component_add_button = eng.ui.widgets.badge.create(imui, "add", key ++ .{@src()});
        if (component_add_button.clicked) {
            // add component with the same name as what is in the line edit
            inline for (ecs_component_info.@"struct".fields, 0..) |_, idx| {
                if (std.mem.eql(u8, line_edit_data.text.items, @typeName(eng.AppEcsSystem.ComponentTypes[idx]))) {
                    _ = eng.get().ecs.add_component(eng.AppEcsSystem.ComponentTypes[idx], entity) catch |err| {
                        std.log.err("Unable to add component '{s}' to entity: {}", .{@typeName(eng.AppEcsSystem.ComponentTypes[idx]), err});
                    };
                    break;
                }
            }
            line_edit_data.text.clearRetainingCapacity();
        }

        // if the dropdown should be shown then render it
        dropdown_is_open: { if (data.dropdown_is_open) {
            // determine the position of the dropdown options based on the primary combobox rect
            const dropdown_pos = if (imui.get_widget_from_last_frame(component_search_line_edit.id.box)) |b| 
                .{ b.rect().left, b.rect().bottom + 4 }
                else break :dropdown_is_open;

            // push the options background layout
            const options_background = imui.push_priority_floating_layout(.Y, dropdown_pos[0], dropdown_pos[1], key ++ .{@src()});
            if (imui.get_widget(options_background)) |options_background_widget| {
                options_background_widget.semantic_size[0] = .{
                    .kind = .ParentPercentage, .value = 1.0, .shrinkable = true,
                };
                options_background_widget.semantic_size[1] = .{
                    .kind = .ChildrenSize, .value = 1.0, .shrinkable = true,
                };

                options_background_widget.flags.render = true;
                options_background_widget.border_width_px = .all(1);
                options_background_widget.padding_px = .all(4);
                options_background_widget.children_gap = 2;
                options_background_widget.corner_radii_px = .all(4);
            }

            // push each of the options into the dropdown menu
            const lower_line_edit_text = std.ascii.allocLowerString(eng.get().frame_allocator, line_edit_data.text.items) catch unreachable;
            defer eng.get().frame_allocator.free(lower_line_edit_text);

            for (data.options.items, 0..) |option, i| {
                const lower_option = std.ascii.allocLowerString(eng.get().frame_allocator, option) catch unreachable;
                defer eng.get().frame_allocator.free(lower_option);

                //if (fuzzy_distance(option, line_edit_data.text.items) < 0.7) { continue; }
                if (lower_line_edit_text.len > 0) {
                    if (std.mem.count(u8, lower_option, lower_line_edit_text) == 0) { continue; }
                }

                const option_background = imui.push_layout(.X, key ++ .{@src(), i});
                defer imui.pop_layout();

                // give the option a hover effect
                if (imui.get_widget(option_background)) |option_background_widget| {
                    option_background_widget.semantic_size[0] = .{
                        .kind = .ParentPercentage, .value = 1.0, .shrinkable = true,
                    };
                    option_background_widget.flags.clickable = true;
                    option_background_widget.flags.render = true;
                    option_background_widget.padding_px = .all(4);
                    option_background_widget.corner_radii_px = .all(4);
                }

                // if the option is clicked then set text field
                if (imui.generate_widget_signals(option_background).clicked) {
                    line_edit_data.text.clearRetainingCapacity();
                    line_edit_data.text.appendSlice(imui.widget_allocator(), option) catch unreachable;
                }
                
                _ = eng.ui.widgets.label.create(imui, option);
            }

            imui.pop_layout(); // options background layout
        } }
    }

    // render component UIs
    inline for (ecs_component_info.@"struct".fields, 0..) |_, idx| {
        if (eng.get().ecs.get_component(eng.AppEcsSystem.ComponentTypes[idx], entity)) |component| {
            const collapsible_outer_layout = imui.push_layout(.X, key ++ .{@src(), idx});
            if (imui.get_widget(collapsible_outer_layout)) |w| {
                w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
            }

            const collapsible = Imui.widgets.collapsible.create(imui, @typeName(eng.AppEcsSystem.ComponentTypes[idx]), null, key ++ .{@src(), idx});
            const collapsible_open, _ = imui.get_widget_data(bool, collapsible.id) catch .{ &false, .Cont };

            // add remove component button
            const remove_button = eng.ui.widgets.badge.create(imui, "-", key ++ .{@src(), idx});

            // dont enable remove button functionality for the transform component.
            // we dont want to make it possible to remove the transform component.
            // TODO make this visible by greying out the button
            if (eng.AppEcsSystem.ComponentTypes[idx] != eng.entity.TransformComponent) {
                if (remove_button.clicked) {
                    eng.get().ecs.remove_component(eng.AppEcsSystem.ComponentTypes[idx], entity);
                }
            }

            imui.pop_layout();

            if (collapsible_open.*) {
                const component_outer_layout = imui.push_layout(.Y, key ++ .{@src(), idx});
                defer imui.pop_layout();

                if (imui.get_widget(component_outer_layout)) |w| {
                    w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true };
                    w.padding_px.left = 20.0;
                    w.children_gap = 5.0;
                }

                eng.AppEcsSystem.ComponentTypes[idx].editor_ui(imui, entity, component, key ++ .{@src(), idx}) catch |err| {
                    std.log.warn("Failed to load editor ui for component '{s}': {}", .{@typeName(eng.AppEcsSystem.ComponentTypes[idx]), err});
                };
            }
        }
    }

    // {
    //     const ll = imui.push_layout(.X, .{@src()});
    //     if (imui.get_widget(ll)) |ll_widget| {
    //         ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, };
    //         ll_widget.children_gap = 4;
    //     }
    //     defer imui.pop_layout();

    //     const labell = Imui.widgets.label.create(imui, "model: ");
    //     if (imui.get_widget(labell.id)) |label_widget| {
    //         label_widget.semantic_size[0] = form_label_size;
    //     }

    //     const model_combobox = Imui.widgets.combobox.create(imui, key ++ .{@src()});
    //     if (model_combobox.init) {
    //         std.log.info("model combobox init", .{});

    //         const model_combobox_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, model_combobox.id) catch unreachable;
    //         model_combobox_data.default_text = imui.widget_allocator().dupe(u8, "None") catch unreachable;
    //         model_combobox_data.can_be_default = true;

    //         var model_names = get_all_model_names(eng.get().frame_allocator) catch unreachable;
    //         defer model_names.deinit();

    //         for (model_names.names) |option| {
    //             model_combobox_data.append_option(imui.widget_allocator(), option) catch |err| {
    //                 std.log.err("Failed to append combobox option: {}", .{err});
    //                 break;
    //             };
    //         }

    //         const model_text = if (entity.model) |mid| (mid.to_string_identifier(arena.allocator()) catch unreachable) else "None";

    //         model_combobox_data.selected_index = null;
    //         for (model_combobox_data.options.items, 0..) |option, i| {
    //             if (std.mem.eql(u8, option, model_text)) {
    //                 model_combobox_data.selected_index = i;
    //                 break;
    //             }
    //         }
    //     }
    //     if (model_combobox.data_changed) {
    //         const model_combobox_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, model_combobox.id) catch unreachable;
    //         if (model_combobox_data.selected_index) |si| {
    //             if (assets.ModelAssetId.from_string_identifier(model_combobox_data.options.items[si])) |model_id| {
    //                 entity.model = model_id;
    //             } else |_| { 
    //                 std.log.err("Failed to deserialize model id!", .{});
    //             }
    //             _ = arena.reset(.retain_capacity);
    //         } else {
    //             entity.model = null;
    //         }
    //     }
    // }
    // _ = arena.reset(.retain_capacity);

    // const transform_collapsible = Imui.widgets.collapsible.create(imui, "Transform", null, .{@src()});
    // const transform_collapsible_open, _ = imui.get_widget_data(bool, transform_collapsible.id) catch .{ &false, .Cont };

    // if (transform_collapsible_open.*) {
    //     const transform_layout = imui.push_layout(.Y, key ++ .{@src()});
    //     if (imui.get_widget(transform_layout)) |transform_layout_widget| {
    //         transform_layout_widget.semantic_size[0].kind = .ParentPercentage;
    //         transform_layout_widget.semantic_size[0].value = 1.0;
    //         transform_layout_widget.padding_px = .{
    //             .left = EntityEditorTabWidth,
    //         };
    //         transform_layout_widget.children_gap = 5;
    //     }
    //     defer imui.pop_layout();

    //     {
    //         _ = imui.push_form_layout_item(.{@src()});
    //         defer imui.pop_layout();

    //         _ = Imui.widgets.label.create(imui, "position: ");
    //         _ = Imui.widgets.number_slider.create(imui, &entity.transform.position[0], .{}, key ++ .{@src()});
    //         _ = Imui.widgets.number_slider.create(imui, &entity.transform.position[1], .{}, key ++ .{@src()});
    //         _ = Imui.widgets.number_slider.create(imui, &entity.transform.position[2], .{}, key ++ .{@src()});
    //     }
    //     {
    //         _ = imui.push_form_layout_item(.{@src()});
    //         defer imui.pop_layout();

    //         _ = Imui.widgets.label.create(imui, "rotation: ");
    //         var rot = zm.loadArr3(zm.quatToRollPitchYaw(entity.transform.rotation)) * zm.f32x4s(180.0 / std.math.pi);
    //         const rx = Imui.widgets.number_slider.create(imui, &rot[0], .{}, key ++ .{@src()});
    //         const ry = Imui.widgets.number_slider.create(imui, &rot[1], .{}, key ++ .{@src()});
    //         const rz = Imui.widgets.number_slider.create(imui, &rot[2], .{}, key ++ .{@src()});

    //         if (rx.data_changed or ry.data_changed or rz.data_changed) {
    //             rot = rot * zm.f32x4s(std.math.pi / 180.0);
    //             entity.transform.rotation = zm.quatFromRollPitchYawV(rot);
    //         }
    //     }
    //     {
    //         _ = imui.push_form_layout_item(.{@src()});
    //         defer imui.pop_layout();

    //         _ = Imui.widgets.label.create(imui, "scale: ");
    //         _ = Imui.widgets.number_slider.create(imui, &entity.transform.scale[0], .{}, key ++ .{@src()});
    //         _ = Imui.widgets.number_slider.create(imui, &entity.transform.scale[1], .{}, key ++ .{@src()});
    //         _ = Imui.widgets.number_slider.create(imui, &entity.transform.scale[2], .{}, key ++ .{@src()});
    //     }
    // }

    // // physics
    // const physics_collapsible = Imui.widgets.collapsible.create(imui, "Physics", null, key ++ .{@src()});
    // const physics_collapsible_open, _ = imui.get_widget_data(bool, physics_collapsible.id) catch .{ &false, .Cont };
    // if (physics_collapsible_open.*) physics_collapsible_blk: {
    //     const physics_button = Imui.widgets.badge.create(imui, "Set Physics", key ++ .{@src()});
    //     const data, _ = imui.get_widget_data(PhysicsData, physics_button.id.box) catch break :physics_collapsible_blk;

    //     if (physics_button.clicked) {
    //         entity.physics.update_runtime_data(self.selected_entity.?) catch |err| {
    //             std.log.err("Unable to update selected entity physics: {}", .{err});
    //         };
    //     }
        
    //     const physics_combobox = Imui.widgets.combobox.create(imui, key ++ .{@src()});
    //     const physics_combobox_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, physics_combobox.id) catch |err| {
    //         std.log.err("Unable to get physics combobox data: {}", .{err});
    //         unreachable;
    //     };
    //     if (physics_combobox.init) {
    //         physics_combobox_data.default_text = imui.widget_allocator().dupe(u8, "None") catch |err| {
    //             std.log.err("Failed to set default physics combobox text: {}", .{err});
    //             unreachable;
    //         };
    //         physics_combobox_data.can_be_default = false;
        
    //         // generate physics option names from enum
    //         const physics_options_fields = @typeInfo(eng.entity.PhysicsOptionsEnum).@"enum".fields;
    //         inline for (physics_options_fields) |field| {
    //             physics_combobox_data.append_option(imui.widget_allocator(), field.name) catch |err| {
    //                 std.log.err("Failed to append physics option to combobox: {}", .{err});
    //                 unreachable;
    //             };
    //         }
        
    //         // set physics descriptor
    //         data.settings = entity.physics.settings;
    //         physics_combobox_data.selected_index = @intFromEnum(data.settings);
    //     }
    //     if (physics_combobox.data_changed) {
    //         if (physics_combobox_data.selected_index) |si| {
    //             switch (@as(eng.entity.PhysicsOptionsEnum, @enumFromInt(si))) {
    //                 .None => data.settings = .{ .None = {} },
    //                 .Body => data.settings = .{ .Body = .{} },
    //                 .Character => data.settings = .{ .Character = .{} },
    //                 .CharacterVirtual => data.settings = .{ .CharacterVirtual = .{} },
    //             }
    //         }
    //     }

    //     const transform_layout = imui.push_layout(.Y, key ++ .{@src()});
    //     if (imui.get_widget(transform_layout)) |transform_layout_widget| {
    //         transform_layout_widget.semantic_size[0].kind = .ParentPercentage;
    //         transform_layout_widget.semantic_size[0].value = 1.0;
    //         transform_layout_widget.children_gap = 5;
    //         transform_layout_widget.padding_px = .{
    //             .left = EntityEditorTabWidth,
    //         };
    //     }
    //     defer imui.pop_layout();
    
    //     switch (data.settings) {
    //         .None => {},
    //         .Body => |*b| {
    //             physics_shape_editor_ui(entity, &b.settings, key ++ .{@src()});

    //             {
    //                 _ = imui.push_form_layout_item(key ++ .{@src()});
    //                 defer imui.pop_layout();

    //                 _ = Imui.widgets.label.create(imui, "is sensor:");
    //                 _ = Imui.widgets.checkbox.create(imui, &b.is_sensor, "", key ++ .{@src()});
    //             }
    //             {
    //                 _ = imui.push_form_layout_item(key ++ .{@src()});
    //                 defer imui.pop_layout();
                    
    //                 _ = Imui.widgets.label.create(imui, "is static:");
    //                 _ = Imui.widgets.checkbox.create(imui, &b.is_static, "", key ++ .{@src()});
    //             }
    //         },
    //         .Character => |_| {
    //             _ = Imui.widgets.label.create(imui, "is character");
    //         },
    //         .CharacterVirtual => |_| {
    //             _ = Imui.widgets.label.create(imui, "is virtual character");
    //         },
    //     }
    // }

    // const particle_collapsible = Imui.widgets.collapsible.create(imui, "Particle System", null, key ++ .{@src()});
    // defer { 
    //     const particle_collapsible_open, _ = imui.get_widget_data(bool, particle_collapsible.id) catch unreachable;
    //     if (particle_collapsible_open.*) {
    //         const background = imui.push_floating_layout(.Y, 0.0, 0.0, .{@src()});
    //         defer imui.pop_layout();

    //         if (imui.get_widget(background)) |background_widget| {
    //             set_background_widget_layout(background_widget);
    //         }

    //         const background_signals = imui.generate_widget_signals(background);
    //         const position_data, const position_state = imui.get_widget_data([2]f32, background) catch unreachable;

    //         if (position_state == .Init) {
    //             position_data[0] = 20.0;
    //             position_data[1] = 20.0;
    //         }

    //         imui.set_floating_layout_position(background, position_data[0], position_data[1]);

    //         if (background_signals.dragged) {
    //             position_data[0] += eng.get().input.mouse_delta[0];
    //             position_data[1] += eng.get().input.mouse_delta[1];
    //         }

    //         if (imui.get_widget(background)) |background_widget| {
    //             background_widget.computed_relative_position[0] = position_data[0];
    //             background_widget.computed_relative_position[1] = position_data[1];
    //         }

    //         pe.particle_editor(entity, key ++ .{@src()});
    //     }
    // }

    // const light_collapsible = Imui.widgets.collapsible.create(imui, "Light", null, key ++ .{@src()});
    // const light_collapsible_open, _ = imui.get_widget_data(bool, light_collapsible.id) catch .{ &false, .Cont };
    // if (light_collapsible_open.*) {
    //     const light_type_combobox = Imui.widgets.combobox.create(imui, key ++ .{@src()});
    //     const light_type_combobox_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, light_type_combobox.id) catch unreachable;
    //     if (light_type_combobox.init) {
    //         light_type_combobox_data.default_text = imui.widget_allocator().dupe(u8, "None") catch unreachable;
    //         light_type_combobox_data.can_be_default = true;

    //         const light_type_options_fields = @typeInfo(StandardRenderer.LightType).@"enum".fields;
    //         inline for (light_type_options_fields) |field| {
    //             light_type_combobox_data.append_option(imui.widget_allocator(), field.name) catch unreachable;
    //         }

    //         light_type_combobox_data.selected_index = if (entity.app.light) |l| @intFromEnum(l.light_type) else null;
    //     }
    //     if (light_type_combobox.data_changed) {
    //         if (light_type_combobox_data.selected_index) |si| {
    //             if (entity.app.light == null) {
    //                 entity.app.light = .{
    //                     .intensity = 1.0,
    //                 };
    //             }
    //             entity.app.light.?.light_type = @as(StandardRenderer.LightType, @enumFromInt(si));
    //         } else {
    //             entity.app.light = null;
    //         }
    //     }
    //     if (entity.app.light) |*light| {
    //         {
    //             _ = imui.push_form_layout_item(.{@src()});
    //             defer imui.pop_layout();

    //             _ = Imui.widgets.label.create(imui, "colour: ");
                
    //             // _ = imui.push_layout(.X, key ++ .{@src()});
    //             // defer imui.pop_layout();

    //             // if (imui.get_widget(container_layout)) |c| {
    //             //     c.semantic_size[0] = Imui.SemanticSize { .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0 };
    //             //     c.semantic_size[1] = Imui.SemanticSize { .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0 };
    //             // }

    //             var colour: ?zm.F32x4 = light.colour;
    //             const colour_indicator_signals = Imui.widgets.colour_indicator.create(imui, &colour.?, key ++ .{@src()});
    //             const colour_indicator_data, _ = imui.get_widget_data(bool, colour_indicator_signals.id) catch unreachable;

    //             if (colour_indicator_signals.init) {
    //                 colour_indicator_data.* = false;
    //             }

    //             if (colour_indicator_signals.clicked) {
    //                 colour_indicator_data.* = !colour_indicator_data.*;
    //             }

    //             if (colour_indicator_data.*) {
    //                 const picker_floating_layout = imui.push_floating_layout(.Y, 10.0, 10.0, key ++ .{@src()});
    //                 defer imui.pop_layout();

    //                 if (imui.get_widget(picker_floating_layout)) |w| {
    //                     set_background_widget_layout(w);
    //                     w.semantic_size[0].minimum_pixel_size = 350;
    //                     w.semantic_size[1].minimum_pixel_size = 350;
    //                 }

    //                 const picker_floating_position, _ = imui.get_widget_data([2]f32, picker_floating_layout) catch unreachable;
    //                 imui.set_floating_layout_position(picker_floating_layout, picker_floating_position[0], picker_floating_position[1]);

    //                 if (imui.generate_widget_signals(picker_floating_layout).dragged) {
    //                     picker_floating_position[0] += eng.get().input.mouse_delta[0];
    //                     picker_floating_position[1] += eng.get().input.mouse_delta[1];
    //                 }

    //                 _ = Imui.widgets.label.create(imui, "colour picker");
    //                 const picker_signals = Imui.widgets.colour_picker.create(imui, &colour, key ++ .{@src()});
    //                 if (picker_signals.data_changed) {
    //                     if (colour) |c| {
    //                         light.colour = c;
    //                     }
    //                 }
    //             }
    //             //_ = Imui.widgets.colour_picker.create(imui, &colour, key ++ .{@src()});

    //             // _ = Imui.widgets.number_slider.create(imui, &light.colour[0], .{}, key ++ .{@src()});
    //             // _ = Imui.widgets.number_slider.create(imui, &light.colour[1], .{}, key ++ .{@src()});
    //             // _ = Imui.widgets.number_slider.create(imui, &light.colour[2], .{}, key ++ .{@src()});
    //         }

    //         create_form_number_slider("intensity:", &light.intensity, key ++ .{@src()});

    //         if (light.light_type == .Spot) {
    //             var umbra_degrees = std.math.radiansToDegrees(light.umbra);
    //             create_form_number_slider("umbra:", &umbra_degrees, key ++ .{@src()});
    //             light.umbra = std.math.degreesToRadians(umbra_degrees);

    //             var penumbra_degrees = std.math.radiansToDegrees(light.delta_penumbra);
    //             create_form_number_slider("delta penumbra:", &penumbra_degrees, key ++ .{@src()});
    //             light.delta_penumbra = std.math.degreesToRadians(penumbra_degrees);
    //         }
    //     }
    // }

    // const terrain_collapsible = Imui.widgets.collapsible.create(imui, "Terrain", null, key ++ .{@src()});
    // const terrain_collapsible_open, _ = imui.get_widget_data(bool, terrain_collapsible.id) catch .{ &false, .Cont };
    // if (terrain_collapsible_open.*) {
    //     var enable_terrain_value: bool = entity.app.terrain != null;
    //     const enable_terrain_checkbox = Imui.widgets.checkbox.create(imui, &enable_terrain_value, "Enable Terrain", key ++ .{@src()});
    //     if (enable_terrain_checkbox.clicked) {
    //         if (entity.app.terrain == null) {
    //             entity.app.terrain = Terrain.init(eng.get().general_allocator) catch |err| {
    //                 std.log.err("Failed to create terrain: {}", .{err});
    //                 return;
    //             };
    //         } else {
    //             if (entity.app.terrain) |*terrain| {
    //                 terrain.deinit();
    //             }
    //             entity.app.terrain = null;
    //         }
    //     }

    //     if (entity.app.terrain) |*terrain| {
    //         terrain.editor_ui(entity, key ++ .{@src()});
    //     }

    //     _ = Imui.widgets.line_edit.create(imui, .{ .allowed_character_set = .RealNumber, }, key ++ .{@src()});
    // }

    // const cloud_volume_collapsible = Imui.widgets.collapsible.create(imui, "Cloud Volume", null, key ++ .{@src()});
    // const cloud_volume_collapsible_open, _ = imui.get_widget_data(bool, cloud_volume_collapsible.id) catch .{ &false, .Cont };
    // if (cloud_volume_collapsible_open.*) {
    //     var enable_value: bool = entity.app.cloud_volume != null;
    //     const enable_checkbox = Imui.widgets.checkbox.create(imui, &enable_value, "Enable Cloud Volume", key ++ .{@src()});
    //     if (enable_checkbox.clicked) {
    //         if (entity.app.cloud_volume == null) {
    //             entity.app.cloud_volume = 1;
    //         } else {
    //             entity.app.cloud_volume = null;
    //         }
    //     }
    // }
}

fn physics_shape_editor_ui(
    entity: *eng.entity.EntitySuperStruct,
    shape_settings: *eng.physics.ShapeSettings, 
    key: anytype
) void {
    const imui = &eng.get().imui;

    const shape_combobox = Imui.widgets.combobox.create(imui, key ++ .{@src()});
    const shape_combobox_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, shape_combobox.id) catch |err| {
        std.log.err("Unable to get combobox widget data: {}", .{ err });
        unreachable;
    };
    if (shape_combobox.init) {
        shape_combobox_data.can_be_default = false;
        const shape_fields = @typeInfo(eng.physics.ShapeSettingsEnum).@"enum".fields;
        inline for (shape_fields) |field| {
            shape_combobox_data.append_option(imui.widget_allocator(), field.name) catch |err| {
                std.log.err("Failed to append physics option to combobox: {}", .{err});
                unreachable;
            };
        }
    }
    if (shape_combobox.data_changed) {
        if (shape_combobox_data.selected_index) |si| {
            switch (@as(eng.physics.ShapeSettingsEnum, @enumFromInt(si))) {
                .Capsule => shape_settings.shape = .{ .Capsule = .{
                    .half_height = 0.7,
                    .radius = 0.2,
                } },
                .Sphere => shape_settings.shape = .{ .Sphere = .{
                    .radius = 1.0,
                } },
                .Box => shape_settings.shape = .{ .Box = .{
                    .width = 1.0,
                    .height = 1.0,
                    .depth = 1.0,
                } },
                .ModelCompoundConvexHull => shape_settings.shape = .{ .ModelCompoundConvexHull = entity.model.? },
            }
        }
    }

    const sl = imui.push_layout(.Y, key ++ .{@src()});
    if (imui.get_widget(sl)) |sl_widget| {
        sl_widget.semantic_size[0].kind = .ParentPercentage;
        sl_widget.semantic_size[0].value = 1.0;
        sl_widget.padding_px = .{
            .left = EntityEditorTabWidth,
        };
        sl_widget.children_gap = 5;
    }

    switch (shape_settings.shape) {
        .Capsule => |*c| {
            create_form_number_slider("radius:", &c.radius, key ++ .{@src()});
            var height = c.half_height * 2.0;
            create_form_number_slider("height:", &height, key ++ .{@src()});
            c.half_height = height * 0.5;
        },
        .Sphere => |*s| {
            create_form_number_slider("radius:", &s.radius, key ++ .{@src()});
        },
        .Box => |*b| {
            create_form_number_slider("width:", &b.width, key ++ .{@src()});
            create_form_number_slider("height:", &b.height, key ++ .{@src()});
            create_form_number_slider("depth:", &b.depth, key ++ .{@src()});
        },
        .ModelCompoundConvexHull => |_| {
        },
    }

    imui.pop_layout(); // sl
}

fn ocean_edit_ui(self: *Self, imui: *Imui, ocean: *Ocean, key: anytype) void {
    const background_box = imui.push_floating_layout(.Y, 100.0, 100.0, key ++ .{@src()});
    defer imui.pop_layout();

    const ocean_editor_background_position, _ = imui.get_widget_data([2]f32, background_box) catch unreachable;
    imui.set_floating_layout_position(background_box, ocean_editor_background_position[0], ocean_editor_background_position[1]);

    if (imui.get_widget(background_box)) |background_widget| {
        set_background_widget_layout(background_widget);
    }
    if (imui.generate_widget_signals(background_box).dragged) {
        ocean_editor_background_position[0] += eng.get().input.mouse_delta[0];
        ocean_editor_background_position[1] += eng.get().input.mouse_delta[1];
    }

    {
        const title_layout = imui.push_layout(.X, key ++ .{@src()});
        defer imui.pop_layout();
        if (imui.get_widget(title_layout)) |tw| {
            tw.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0 };
        }

        {
            const label_layout = imui.push_layout(.X, key ++ .{@src()});
            defer imui.pop_layout();
            if (imui.get_widget(label_layout)) |lw| {
                lw.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, };
            }

            _ = Imui.widgets.label.create(imui, "Ocean Settings");
        }

        const close_badge = Imui.widgets.badge.create(imui, "close", key ++ .{@src()});
        if (close_badge.clicked) {
            self.edit_ocean_params_open = false;
        }
        if (imui.get_widget(close_badge.id.box)) |cw| {
            cw.semantic_size[0].shrinkable = false;
        }
    }

    var ocean_settings = ocean.current_settings;

    {
        const form_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();
        if (imui.get_widget(form_layout)) |fw| {
            fw.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0 };
            fw.children_gap = 5.0;
        }

        create_form_number_slider("amplitude:", &ocean_settings.amplitude, key ++ .{@src()});
        create_form_number_slider("wind_x:", &ocean_settings.wind[0], key ++ .{@src()});
        create_form_number_slider("wind_z:", &ocean_settings.wind[1], key ++ .{@src()});
    }

    if (!std.mem.eql(u8, @ptrCast(&ocean_settings), @ptrCast(&ocean.current_settings))) (blk: {
        var pool = gfx.CommandPool.init(.{ .queue_family = .Compute }) catch |err| break :blk err;
        defer pool.deinit();

        var cmd = (pool.get() catch |err| break :blk err).allocate_command_buffer(.{}) catch |err| break :blk err;
        defer cmd.deinit();

        cmd.cmd_begin(.{ .one_time_submit = true, }) catch |err| break :blk err;
        ocean.recreate_h0_image(&cmd, ocean_settings);
        cmd.cmd_end() catch |err| break :blk err;

        var fence = gfx.Fence.init(.{}) catch |err| break :blk err;
        defer fence.deinit();

        gfx.GfxState.get().submit_command_buffer(.{
            .command_buffers = &.{ &cmd },
            .fence = fence,
        }) catch |err| break :blk err;

        fence.wait() catch |err| break :blk err;
    }) catch |err| {
        std.log.warn("Unable to update ocean parameters: {}", .{err});
    };
}

fn create_form_number_slider(
    text: []const u8,
    value: *f32, 
    key: anytype
) void {
    const imui = &eng.get().imui;

    _ = imui.push_form_layout_item(key ++ .{@src()});
    defer imui.pop_layout();

    _ = Imui.widgets.label.create(imui, text);
    _ = Imui.widgets.number_slider.create(imui, value, .{}, key ++ .{@src()});
}

const LoadScenePopup = struct {
    selected_name: ?[]u8 = null,

    pub fn deinit(self: *LoadScenePopup) void {
        self.set_selected_name(null) catch unreachable;
    }

    pub fn init() !LoadScenePopup {
        return .{};
    }

    pub fn set_selected_name(self: *LoadScenePopup, name: ?[]const u8) !void {
        if (self.selected_name) |s| {
            eng.get().general_allocator.free(s);
        }
        self.selected_name = if (name) |n| try eng.get().general_allocator.dupe(u8, n) else null;
    }
};

fn load_scene_popup(self: *Self, data: *LoadScenePopup, key: anytype) !void {
    const imui = &eng.get().imui;

    _ = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    var scenes_dir = try open_scenes_dir(true);
    defer scenes_dir.close();

    var iter = scenes_dir.iterate();

    var idx: i32 = 0;
    while (try iter.next()) |v| {
        idx += 1;
        if (v.kind != .directory) {
            continue;
        }

        const b = Imui.widgets.button.create(imui, v.name, key ++ .{@src(), idx});
        if (b.clicked) {
           try data.set_selected_name(v.name);
        }
    }

    const create_new_button = Imui.widgets.button.create(imui, "create new", key ++ .{@src()});
    if (create_new_button.clicked) {
        std.log.info("should create new scene...", .{});
    }

    _ = Imui.widgets.label.create(imui, try std.fmt.allocPrint(eng.get().frame_allocator, "Scene to load: '{s}'", .{ data.selected_name orelse "None" }));

    {
        _ = imui.push_layout(.X, key ++ .{@src()});
        defer imui.pop_layout();

        const load_button = Imui.widgets.button.create(imui, "Load", key ++ .{@src()});
        if (load_button.clicked) {
            if (data.selected_name) |name| {
                // Remove all existing entities
                var entity_iterator = eng.get().ecs.entity_iterator();
                while (entity_iterator.next()) |entity| {
                    eng.get().ecs.remove_entity(entity);
                }

                // Create new entities and set scene name
                try create_scene_entities(name);
                try self.set_loaded_scene_name(name);

                // close the load scene popup
                self.load_scene_popup_is_open = false;
                try data.set_selected_name(null);
            }
        }

        const cancel_button = Imui.widgets.button.create(imui, "Cancel", key ++ .{@src()});
        if (cancel_button.clicked) {
            self.load_scene_popup_is_open = false;
        }
    }
}

fn open_scenes_dir(enableIterate: bool) !std.fs.Dir {
    return try std.fs.cwd().makeOpenPath("scenes", .{ .iterate = enableIterate, });
}

fn create_scene_entities(scene_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
    defer arena.deinit();

    var scenes_dir = try open_scenes_dir(true);
    defer scenes_dir.close();

    var dir = try scenes_dir.openDir(scene_name, .{.iterate = true,});
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
                std.json.Value,
                arena.allocator(),
                ent_str,
                .{ .ignore_unknown_fields = true, }
            ) catch |err| {
                std.log.err("Failed to parse file {s}: {}", .{ entry.name, err });
                continue;
            };

            const new_entity = eng.get().ecs.deserialize_to_entity(ent_s) catch |err| {
                std.log.err("Failed to deserialize entity {s}: {}", .{ entry.name, err });
                continue;
            };
            
            // all loaded entities will be serialized so make sure it has the serialization component
            _ = eng.get().ecs.add_component(eng.entity.SerializationComponent, new_entity) catch |err| {
                std.log.warn("Unable to add serialization component to new entity: {}", .{err});
            };

            // TODO maybe need a post-deserialize in entity super struct?
            // if (eng.get().ecs.get_component(eng.entity.PhysicsComponent, new_entity)) |physics_component| {
            //     physics_component.update_runtime_data(new_entity) catch |err| {
            //         std.log.err("Unable to update entity physics: {}", .{err});
            //     };
            // }

            std.log.info("Loaded entity: {}", .{new_entity});
        }
    }
}

fn save_entities_to_scene(scene_name: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(eng.get().general_allocator);
    defer arena.deinit();

    var scenes_dir = try open_scenes_dir(true);
    defer scenes_dir.close();

    scenes_dir.deleteTree(scene_name) catch |err| {
        std.debug.print("unable to delete scene {s}: {}\n", .{scene_name, err});
    };

    var scene_dir = try scenes_dir.makeOpenPath(scene_name, .{ .iterate = true, });
    defer scene_dir.close();


    var serialize_component_iterator = eng.get().ecs.component_iterator(eng.entity.SerializationComponent);
    var largest_serialize_id: u32 = 0;
    while (serialize_component_iterator.next()) |serialize_component| {
        largest_serialize_id = @max(largest_serialize_id, serialize_component.serialize_id orelse 0);
    }

    var entity_iterator = eng.get().ecs.entity_iterator();
    while (entity_iterator.next()) |entity| {

        _ = arena.reset(.retain_capacity);

        const entity_serialize_component = eng.get().ecs.get_component(eng.entity.SerializationComponent, entity)
            orelse continue;

        entity_serialize_component.serialize_id = entity_serialize_component.serialize_id orelse blk: {
            largest_serialize_id += 1;
            break :blk largest_serialize_id;
        };

        const entity_s = eng.get().ecs.serialize_entity(arena.allocator(), entity) catch |err| {
            std.log.err("unable to produce serializable for entity {}: {}\n", .{entity_serialize_component.serialize_id.?, err});
            continue;
        };

        var json_writer = std.io.Writer.Allocating.init(arena.allocator());
        defer json_writer.deinit();

        var json = std.json.Stringify{
            .writer = &json_writer.writer,
        };
        json.options.whitespace = .indent_2;

        json.write(entity_s) catch |err| {
            std.log.err("unable to produce json for entity {}: {}\n", .{entity_serialize_component.serialize_id.?, err});
            continue;
        };

        const file_path = std.fmt.allocPrint(arena.allocator(), "{d}.json", .{entity_serialize_component.serialize_id.?}) catch |err| {
            std.log.err("unable to produce file path for entity {}: {}\n", .{entity_serialize_component.serialize_id.?, err});
            continue;
        };

        scene_dir.writeFile(.{
            .sub_path = file_path,
            .data = json_writer.written(),
            .flags = .{ .read = false, .truncate = true, },
        }) catch |err| {
            std.log.err("unable to write file for entity {}: {}\n", .{entity_serialize_component.serialize_id.?, err});
            continue;
        };
    }
}
