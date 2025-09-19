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

const zm = eng.zmath;
const sr = eng.serialize;
const assets = eng.assets;
const KeyCode = eng.input.KeyCode;
const EntityDescriptor = eng.Engine.EntityDescriptor;
const Transform = eng.Transform;
const Camera = eng.camera.Camera;
const Imui = eng.ui.Imui;
const GenerationalIndex = eng.gen.GenerationalIndex;

const EditorMode = enum {
    SceneEditor,
};

editor_camera: Camera,
gizmo: Gizmo,
selected_entity: ?GenerationalIndex = null,
render_only_selected_entity: bool = false,

file_dropdown_open: bool = false,
edit_dropdown_open: bool = false,

loaded_scene_name: ?[]u8 = null,

load_scene_popup_data: LoadScenePopup,
load_scene_popup_is_open: bool = false,

pub fn deinit(self: *Self) void {
    self.load_scene_popup_data.deinit();
    self.set_loaded_scene_name(null) catch unreachable;
    self.gizmo.deinit();
}

pub fn init() !Self {
    return Self {
        .gizmo = try Gizmo.init(eng.get().general_allocator),
        .load_scene_popup_data = try LoadScenePopup.init(),
        .editor_camera = Camera {
            .field_of_view_y = Camera.horizontal_to_vertical_fov(std.math.degreesToRadians(90.0), eng.get().gfx.swapchain_aspect()),
            .near_field = 0.3,
            .far_field = 1000.0,
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

pub fn update(self: *Self, selection_textures: *st.SelectionTextures(u32), terrain_renderer: *TerrainRenderer) !void {
    if (!eng.get().imui.has_focus()) {
        self.editor_camera.fly_camera_update(&eng.get().window, &eng.get().input, &eng.get().time);

        // focus camera on selected entity
        if (eng.get().input.get_key_down(KeyCode.F)) blk: {
            if (self.selected_entity) |si| {
                const selected_entity = eng.get().entities.get(si) orelse break :blk;
                self.editor_camera.transform.position = 
                    selected_entity.transform.position -
                    (self.editor_camera.transform.forward_direction() * zm.f32x4s(10.0));
            }
        }

        self.render_only_selected_entity = eng.get().input.get_key(KeyCode.G);

        // new entity button
        if (eng.get().input.get_key_down(KeyCode.E)) {
            self.create_new_entity();
        }

        // delete entity button
        if (eng.get().input.get_key_down(KeyCode.Delete)) {
            self.remove_selected_entity();
        }

        var interaction_available = true;

        if (interaction_available) {
            if (self.selected_entity) |selected_entity| blk: {
                const entity = eng.get().entities.get(selected_entity) orelse break :blk;
                if (self.gizmo.update(&entity.transform)) {
                    interaction_available = false;
                }
            }
        }

        if (interaction_available) {
            if (self.selected_entity) |selected_entity| blk: {
                const ent = eng.get().entities.get(selected_entity) orelse break :blk;
                if (ent.app.terrain) |*terrain| {
                    const modified = terrain.edit_terrain(terrain_renderer) catch |err| {
                        std.log.err("Failed to edit terrain: {}", .{err});
                        break :blk;
                    };
                    if (modified) {
                        interaction_available = false;
                    }
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
            } else if (self.selected_entity != null and self.selected_entity.?.index == selection_entity_id) {
                self.selected_entity = null;
            } else {
                const entity = eng.get().entities.get_dont_check_generation(selection_entity_id);
                if (entity) |ent| {
                    std.log.info("entity name: {s}", .{ent.name orelse "unnamed"});
                    self.selected_entity = .{
                        .index = selection_entity_id,
                        .generation = eng.get().entities.list.data.items[selection_entity_id].generation,
                    };
                } else {
                    std.log.info("entity not found!", .{});
                }
            }
        }
    }

    const imui = &eng.get().imui;

    self.entity_editor_ui(.{self.selected_entity, @src()});

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
            .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 },
            .{ .kind = .ChildrenSize, .value = 1.0, .shrinkable_percent = 0.0 },
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

    const l = imui.label(try std.fmt.allocPrint(eng.get().frame_allocator, "Edit Mode{s}", .{
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
        const file_button = imui.button("File", key ++ .{@src()});
        if (imui.get_widget(file_button.id.box)) |file_widget| {
            file_widget.background_colour = zm.f32x4s(0.0);
            file_widget.border_width_px = .{};
            file_widget.padding_px = .lr_tb(10, 5);
        }
        if (imui.get_widget(file_button.id.text)) |text_widget| {
            text_widget.text_content.?.colour = imui.palette().text_dark;
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
                const file_lfw_rect = file_lfw.computed.rect();
                const file_dropdown = imui.push_priority_floating_layout(.Y, file_lfw_rect.left, file_lfw_rect.bottom, key ++ .{@src()});
                if (imui.get_widget(file_dropdown)) |file_dropdown_widget| {
                    file_dropdown_widget.flags.render = true;
                }
                defer imui.pop_layout();

                const save_button = imui.badge("Save Scene", key ++ .{@src()});
                if (save_button.clicked) {
                    if (self.loaded_scene_name) |scene_name| {
                        save_entities_to_scene(scene_name) catch |err| {
                            std.log.err("Failed to save scene: {}", .{err});
                        };
                        std.log.debug("saved scene {s}!", .{scene_name});
                    }
                }
                const load_button = imui.badge("Load Scene", key ++ .{@src()});
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
        const edit_button = imui.button("Edit", key ++ .{@src()});
        if (imui.get_widget(edit_button.id.box)) |edit_widget| {
            edit_widget.background_colour = zm.f32x4s(0.0);
            edit_widget.border_width_px = .{};
            edit_widget.padding_px = .lr_tb(10, 5);
        }
        if (imui.get_widget(edit_button.id.text)) |text_widget| {
            text_widget.text_content.?.colour = imui.palette().text_dark;
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
                const edit_lfw_rect = edit_lfw.computed.rect();
                const edit_dropdown = imui.push_priority_floating_layout(.Y, edit_lfw_rect.left, edit_lfw_rect.bottom, key ++ .{@src()});
                if (imui.get_widget(edit_dropdown)) |edit_dropdown_widget| {
                    edit_dropdown_widget.flags.render = true;
                }
                defer imui.pop_layout();

                const new_button = imui.badge("New Entity", key ++ .{@src()});
                if (new_button.clicked) {
                    self.create_new_entity();
                }

                const delete_button = imui.badge("Delete Entity", key ++ .{@src()});
                if (delete_button.clicked) {
                    self.remove_selected_entity();
                }

                const duplicate_button = imui.badge("Duplicate Entity", key ++ .{@src()});
                if (duplicate_button.clicked) {
                    self.duplicate_selected_entity();
                }
            }
        }
    }
}

pub fn render_cmd(self: *Self, cmd: *gfx.CommandBuffer) !void {
    if (self.selected_entity) |s| {
        if (eng.get().entities.get(s)) |entity| {
            self.gizmo.render_cmd(cmd, &entity.transform, &self.editor_camera) catch |err| {
                std.log.warn("Unable to render edit mode gizmo: {}", .{err});
            };
        } 
    }
}

fn create_new_entity(self: *Self) void {
    _ = eng.get().entities.new_entity(EntityDescriptor {
        .name = "new entity",
        .should_serialize = true,
        .model = null,
        .transform = Transform {
            .position = self.editor_camera.transform.position + zm.normalize3(self.editor_camera.transform.forward_direction()),
        },
        }) catch |err| {
        std.log.err("Failed to create entity: {}", .{err});
    };
}

fn duplicate_selected_entity(self: *Self) void {
    if (self.selected_entity) |selected_entity| {
        var descriptor = eng.get().entities.get(selected_entity).?.descriptor(eng.get().frame_allocator) catch |err| {
            std.log.err("Failed to create descriptor for entity: {}", .{err});
            return;
        };

        // clear the serialize id so that it will be generated on the next save
        descriptor.serialize_id = null;

        const new_entity = eng.get().entities.new_entity(descriptor) catch |err| {
            std.log.err("Failed to duplicate entity: {}", .{err});
            return;
        };
        self.selected_entity = new_entity;
        //std.log.info("duplicated entity: {}", .{eng.get().entities.get(new_entity).?});
    }
}

fn remove_selected_entity(self: *Self) void {
    if (self.selected_entity) |selected_entity| {
        eng.get().entities.remove_entity(selected_entity) catch |err| {
            std.log.err("Failed to remove entity: {}", .{err});
        };
        self.selected_entity = null;
    }
}

fn set_background_widget_layout(background_widget: *Imui.Widget) void {
    background_widget.semantic_size[0].minimum_pixel_size = 350;
    background_widget.flags.clickable = true;
    background_widget.flags.render = true;
    background_widget.flags.hover_effect = false;
    background_widget.border_width_px = .all(3);
    background_widget.padding_px = .all(10);
    background_widget.corner_radii_px = .all(10);
    background_widget.children_gap = 5;
}

const ModelNames = struct {
    arena: std.heap.ArenaAllocator,
    names: [][]u8,

    pub fn deinit(self: *ModelNames) void {
        self.arena.allocator().free(self.names);
        self.arena.deinit();
    }
};

fn get_all_model_names(alloc: std.mem.Allocator) !ModelNames {
    var arena = std.heap.ArenaAllocator.init(alloc);
    errdefer arena.deinit();

    // generate model option names from asset packs
    var model_names = std.ArrayList([]u8).init(alloc);
    defer model_names.deinit();

    var asset_packs_iter = eng.get().asset_manager.asset_packs.iterator();
    while (asset_packs_iter.next()) |it| {
        const pack = it.value_ptr;
        var iter = pack.assets.iterator();
        while (iter.next()) |p| {
            switch (p.value_ptr.asset) {
                .Model => {
                    const asset_id = assets.ModelAssetId{ .pack_id = pack.unique_name_hash, .asset_id = p.key_ptr.* };

                    const asset_identifier_string = try asset_id.serialize(alloc);
                    defer alloc.free(asset_identifier_string);

                    try model_names.append(try std.fmt.allocPrint(arena.allocator(), "{s}", .{asset_identifier_string}));
                },
                else => {},
            }
        }
    }

    return ModelNames {
        .arena = arena,
        .names = try model_names.toOwnedSlice(),
    };
}


const EntityEditorTabWidth = 10;
fn entity_editor_ui(
    self: *Self, 
    key: anytype,
) void {
    const imui = &eng.get().imui;
    
    var arena = std.heap.ArenaAllocator.init(eng.get().frame_allocator);
    defer arena.deinit();

    if (self.selected_entity == null) return;
    const entity = eng.get().entities.get(self.selected_entity.?) orelse return;

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

    const entity_editor_background_signals = imui.generate_widget_signals(background_box);
    if (entity_editor_background_signals.init) {
        entity_editor_background_position.* = .{ -10.0, 10.0 };
    }
    if (entity_editor_background_signals.dragged) {
        entity_editor_background_position[0] += eng.get().input.mouse_delta[0];
        entity_editor_background_position[1] += eng.get().input.mouse_delta[1];
    }

    const entity_editor_title_text = imui.label("Entity Editor");
    if (imui.get_widget(entity_editor_title_text.id)) |entity_editor_title_widget| {
        entity_editor_title_widget.anchor = .{ 0.5, 0.5 };
        entity_editor_title_widget.pivot = .{ 0.5, 0.5 };
    }
    _ = imui.checkbox(&entity.should_serialize, "should serialize", key ++ .{@src()});

    {
        const ll = imui.push_layout(.X, key ++ .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        const labell = imui.label("name:");
        if (imui.get_widget(labell.id)) |label_widget| {
            label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable_percent = 0.0 };
        }
        const name_edit = imui.line_edit(key ++ .{@src()});
        // if name line edit has changed then update the entity's name
        if (name_edit.init) {
            const name_edit_data, _ = imui.get_widget_data(eng.ui.Imui.TextInputState, name_edit.id.box) catch unreachable;
            name_edit_data.text.appendSlice(entity.name orelse "unnamed") catch unreachable;
            name_edit_data.cursor = name_edit_data.text.items.len;
            name_edit_data.mark = name_edit_data.text.items.len;
        }
        if (name_edit.data_changed) {
            if (entity.name) |_| {
                const name_edit_data, _ = imui.get_widget_data(eng.ui.Imui.TextInputState, name_edit.id.box) catch unreachable;
                eng.get().general_allocator.free(entity.name.?);
                entity.name = eng.get().general_allocator.dupe(u8, name_edit_data.text.items) catch unreachable;
            }
        }
    }
    _ = arena.reset(.retain_capacity);

    {
        const ll = imui.push_layout(.X, .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        const labell = imui.label("model: ");
        if (imui.get_widget(labell.id)) |label_widget| {
            label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable_percent = 0.0 };
        }

        const model_combobox = imui.combobox(key ++ .{@src()});
        if (model_combobox.init) {
            std.log.info("model combobox init", .{});

            const model_combobox_data, _ = imui.get_widget_data(Imui.ComboBoxState, model_combobox.id) catch unreachable;
            model_combobox_data.default_text.appendSlice("None") catch unreachable;
            model_combobox_data.can_be_default = true;

            var model_names = get_all_model_names(eng.get().frame_allocator) catch unreachable;
            defer model_names.deinit();
            for (model_names.names) |option| {
                model_combobox_data.append_option(option) catch |err| {
                    std.log.err("Failed to append combobox option: {}", .{err});
                    break;
                };
            }

            const model_text = if (entity.model) |mid| 
                sr.serialize(assets.ModelAssetId, arena.allocator(), mid) catch unreachable else "None";
            model_combobox_data.selected_index = null;
            for (model_combobox_data.options.items, 0..) |option, i| {
                if (std.mem.eql(u8, option.items, model_text)) {
                    model_combobox_data.selected_index = i;
                    break;
                }
            }
        }
        if (model_combobox.data_changed) {
            const model_combobox_data, _ = imui.get_widget_data(Imui.ComboBoxState, model_combobox.id) catch unreachable;
            if (model_combobox_data.selected_index) |si| {
                if (sr.deserialize(assets.ModelAssetId, arena.allocator(), model_combobox_data.options.items[si].items)) |model_id| {
                    entity.model = model_id;
                } else |_| { 
                    std.log.err("Failed to deserialize model id!", .{});
                }
                _ = arena.reset(.retain_capacity);
            } else {
                entity.model = null;
            }
        }
    }
    _ = arena.reset(.retain_capacity);

    const transform_collapsible = imui.collapsible("Transform", null, .{@src()});
    const transform_collapsible_open, _ = imui.get_widget_data(bool, transform_collapsible.id) catch .{ &false, .Cont };

    if (transform_collapsible_open.*) {
        const transform_layout = imui.push_layout(.Y, key ++ .{@src()});
        if (imui.get_widget(transform_layout)) |transform_layout_widget| {
            transform_layout_widget.semantic_size[0].kind = .ParentPercentage;
            transform_layout_widget.semantic_size[0].value = 1.0;
            transform_layout_widget.padding_px = .{
                .left = EntityEditorTabWidth,
            };
            transform_layout_widget.children_gap = 5;
        }
        defer imui.pop_layout();

        {
            const pl = imui.push_layout(.X, key ++ .{@src()});
            if (imui.get_widget(pl)) |pl_widget| {
                pl_widget.semantic_size[0].kind = .ParentPercentage;
                pl_widget.semantic_size[0].value = 1.0;
                pl_widget.children_gap = 2;
            }
            defer imui.pop_layout();

            const ll = imui.label("position: ");
            if (imui.get_widget(ll.id)) |ll_widget| {
                ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0, };
            }
            _ = imui.number_slider(&entity.transform.position[0], .{}, key ++ .{@src()});
            _ = imui.number_slider(&entity.transform.position[1], .{}, key ++ .{@src()});
            _ = imui.number_slider(&entity.transform.position[2], .{}, key ++ .{@src()});
        }
        {
            const pl = imui.push_layout(.X, key ++ .{@src()});
            if (imui.get_widget(pl)) |pl_widget| {
                pl_widget.semantic_size[0].kind = .ParentPercentage;
                pl_widget.semantic_size[0].value = 1.0;
                pl_widget.children_gap = 2;
            }
            defer imui.pop_layout();

            const ll = imui.label("rotation: ");
            if (imui.get_widget(ll.id)) |ll_widget| {
                ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0, };
            }
            var rot = zm.loadArr3(zm.quatToRollPitchYaw(entity.transform.rotation)) * zm.f32x4s(180.0 / std.math.pi);
            _ = imui.number_slider(&rot[0], .{}, key ++ .{@src()});
            _ = imui.number_slider(&rot[1], .{}, key ++ .{@src()});
            _ = imui.number_slider(&rot[2], .{}, key ++ .{@src()});

            // TODO set entity rotation when number sliders change
            //entity.transform.rotation = zm.quatFromRollPitchYawV(rot / zm.f32x4s(180.0 / std.math.pi));
        }
        {
            const pl = imui.push_layout(.X, key ++ .{@src()});
            if (imui.get_widget(pl)) |pl_widget| {
                pl_widget.semantic_size[0].kind = .ParentPercentage;
                pl_widget.semantic_size[0].value = 1.0;
                pl_widget.children_gap = 2;
            }
            defer imui.pop_layout();

            const ll = imui.label("scale: ");
            if (imui.get_widget(ll.id)) |ll_widget| {
                ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0, };
            }
            _ = imui.number_slider(&entity.transform.scale[0], .{}, key ++ .{@src()});
            _ = imui.number_slider(&entity.transform.scale[1], .{}, key ++ .{@src()});
            _ = imui.number_slider(&entity.transform.scale[2], .{}, key ++ .{@src()});
        }
    }

    // physics
    const physics_collapsible = imui.collapsible("Physics", null, key ++ .{@src()});
    const physics_collapsible_open, _ = imui.get_widget_data(bool, physics_collapsible.id) catch .{ &false, .Cont };
    if (physics_collapsible_open.*) {
        // TODO fix this
        //
        // const physics_button = imui.badge("Set Physics", key ++ .{@src()});
        // if (physics_button.clicked) {
        //     if (data.physics_combobox_data.selected_index) |_| {
        //         entity.set_physics(self.selected_entity.?, data.running_physics_desc.?, &eng.get().physics) catch unreachable;
        //     } else {
        //         entity.remove_physics(&eng.get().physics);
        //     }
        // }
        //
        // data.physics_combobox_data.selected_index = if (data.running_physics_desc) |d| @intFromEnum(d) else null;
        // const physics_combobox = imui.combobox(&data.physics_combobox_data, key ++ .{@src()});
        // const physics_combobox_data = imui.get_widget_data(Imui.ComboBoxState, physics_combobox.id) catch |err| {
        //     std.log.err("Unable to get physics combobox data: {}", .{err});
        //     unreachable;
        // };
        // if (physics_combobox.init) {
        //     physics_combobox_data.default_text.appendSlice("None") catch |err| {
        //         std.log.err("Failed to set default physics combobox text: {}", .{err});
        //         unreachable;
        //     };
        //     physics_combobox_data.can_be_default = true;
        //
        //     // generate physics option names from enum
        //     const physics_options_fields = @typeInfo(eng.entity.PhysicsOptionsEnum).@"enum".fields;
        //     inline for (physics_options_fields) |field| {
        //         physics_combobox_data.append_option(field.name) catch |err| {
        //             std.log.err("Failed to append physics option to combobox: {}", .{err});
        //             unreachable;
        //         };
        //     }
        //
        //     // set physics descriptor
        //     if (entity.physics) |*physics| {
        //         physics_combobox_data.selected_index = @intFromEnum(physics.descriptor().?);
        //     } else {
        //         physics_combobox_data.selected_index = null;
        //     }
        // }
        // if (physics_combobox.data_changed) {
        //     if (physics_combobox_data.selected_index) |si| {
        //         switch (@as(eng.entity.PhysicsOptionsEnum, @enumFromInt(si))) {
        //             .Body => data.running_physics_desc = .{ .Body = .{} },
        //             .Character => data.running_physics_desc = .{ .Character = .{} },
        //             .CharacterVirtual => data.running_physics_desc = .{ .CharacterVirtual = .{} },
        //         }
        //     }
        // }
        // if (physics_combobox_data.selected_index != null) {
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
        //
        //     if (data.running_physics_desc) |*running_physics_desc| {
        //         switch (running_physics_desc.*) {
        //             .Body => |*b| {
        //                 physics_shape_editor_ui(entity, &b.settings, data, key ++ .{@src()});
        //                 _ = imui.checkbox(&b.is_sensor, "is sensor", key ++ .{@src()});
        //                 _ = imui.checkbox(&b.is_static, "is static", key ++ .{@src()});
        //             },
        //             .Character => |_| {
        //                 _ = imui.label("is character");
        //             },
        //             .CharacterVirtual => |_| {
        //                 _ = imui.label("is virtual character");
        //             },
        //         }
        //     }
        // }
    }

    const particle_collapsible = imui.collapsible("Particle System", null, key ++ .{@src()});
    defer { 
        const particle_collapsible_open, _ = imui.get_widget_data(bool, particle_collapsible.id) catch unreachable;
        if (particle_collapsible_open.*) {
            const background = imui.push_floating_layout(.Y, 0.0, 0.0, .{@src()});
            defer imui.pop_layout();

            if (imui.get_widget(background)) |background_widget| {
                set_background_widget_layout(background_widget);
            }

            const background_signals = imui.generate_widget_signals(background);
            const position_data, const position_state = imui.get_widget_data([2]f32, background) catch unreachable;

            if (position_state == .Init) {
                position_data[0] = 20.0;
                position_data[1] = 20.0;
            }

            imui.set_floating_layout_position(background, position_data[0], position_data[1]);

            if (background_signals.dragged) {
                position_data[0] += eng.get().input.mouse_delta[0];
                position_data[1] += eng.get().input.mouse_delta[1];
            }

            if (imui.get_widget(background)) |background_widget| {
                background_widget.computed.relative_position[0] = position_data[0];
                background_widget.computed.relative_position[1] = position_data[1];
            }

            pe.particle_editor(entity, key ++ .{@src()});
        }
    }

    const light_collapsible = imui.collapsible("Light", null, key ++ .{@src()});
    const light_collapsible_open, _ = imui.get_widget_data(bool, light_collapsible.id) catch .{ &false, .Cont };
    if (light_collapsible_open.*) {
        const light_type_combobox = imui.combobox(key ++ .{@src()});
        const light_type_combobox_data, _ = imui.get_widget_data(Imui.ComboBoxState, light_type_combobox.id) catch unreachable;
        if (light_type_combobox.init) {
            light_type_combobox_data.default_text.appendSlice("None") catch unreachable;
            light_type_combobox_data.can_be_default = true;

            const light_type_options_fields = @typeInfo(StandardRenderer.LightType).@"enum".fields;
            inline for (light_type_options_fields) |field| {
                light_type_combobox_data.append_option(field.name) catch unreachable;
            }

            light_type_combobox_data.selected_index = if (entity.app.light) |l| @intFromEnum(l.light_type) else null;
        }
        if (light_type_combobox.data_changed) {
            if (light_type_combobox_data.selected_index) |si| {
                if (entity.app.light == null) {
                    entity.app.light = .{
                        .intensity = 1.0,
                    };
                }
                entity.app.light.?.light_type = @as(StandardRenderer.LightType, @enumFromInt(si));
            } else {
                entity.app.light = null;
            }
        }
        if (entity.app.light) |*light| {
            {
                const ll = eng.get().imui.push_layout(.X, key ++ .{@src()});
                if (eng.get().imui.get_widget(ll)) |ll_widget| {
                    ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
                    ll_widget.children_gap = 4;
                }
                defer eng.get().imui.pop_layout();

                _ = imui.label("colour: ");
                _ = imui.number_slider(&light.colour[0], .{}, key ++ .{@src()});
                _ = imui.number_slider(&light.colour[1], .{}, key ++ .{@src()});
                _ = imui.number_slider(&light.colour[2], .{}, key ++ .{@src()});
            }
            labeled_number_slider("intensity:", &light.intensity, key ++ .{@src()});

            if (light.light_type == .Spot) {
                var umbra_degrees = std.math.radiansToDegrees(light.umbra);
                labeled_number_slider("umbra:", &umbra_degrees, key ++ .{@src()});
                light.umbra = std.math.degreesToRadians(umbra_degrees);

                var penumbra_degrees = std.math.radiansToDegrees(light.delta_penumbra);
                labeled_number_slider("delta penumbra:", &penumbra_degrees, key ++ .{@src()});
                light.delta_penumbra = std.math.degreesToRadians(penumbra_degrees);
            }
        }
    }

    const terrain_collapsible = imui.collapsible("Terrain", null, key ++ .{@src()});
    const terrain_collapsible_open, _ = imui.get_widget_data(bool, terrain_collapsible.id) catch .{ &false, .Cont };
    if (terrain_collapsible_open.*) {
        var enable_terrain_value: bool = entity.app.terrain != null;
        const enable_terrain_checkbox = imui.checkbox(&enable_terrain_value, "Enable Terrain", key ++ .{@src()});
        if (enable_terrain_checkbox.clicked) {
            if (entity.app.terrain == null) {
                entity.app.terrain = Terrain.init(eng.get().general_allocator, .{}, entity.transform) catch |err| {
                    std.log.err("Failed to create terrain: {}", .{err});
                    return;
                };
            } else {
                if (entity.app.terrain) |*terrain| {
                    terrain.deinit();
                }
                entity.app.terrain = null;
            }
        }

        if (entity.app.terrain) |*terrain| {
            terrain.editor_ui(entity, key ++ .{@src()});
        }
    }
}

// fn physics_shape_editor_ui(
//     entity: *eng.entity.EntitySuperStruct,
//     shape_settings: *eng.physics.ShapeSettings, 
//     key: anytype
// ) void {
//     const imui = &eng.get().imui;
//     data.shape_combobox_data.selected_index = @intFromEnum(shape_settings.shape);
//     const shape_combobox = imui.combobox(&data.shape_combobox_data, key ++ .{@src()});
//     if (shape_combobox.data_changed) {
//         if (data.shape_combobox_data.selected_index) |si| {
//             switch (@as(eng.physics.ShapeSettingsEnum, @enumFromInt(si))) {
//                 .Capsule => shape_settings.shape = .{ .Capsule = .{
//                     .half_height = 0.7,
//                     .radius = 0.2,
//                 } },
//                 .Sphere => shape_settings.shape = .{ .Sphere = .{
//                     .radius = 1.0,
//                 } },
//                 .Box => shape_settings.shape = .{ .Box = .{
//                     .width = 1.0,
//                     .height = 1.0,
//                     .depth = 1.0,
//                 } },
//                 .ModelCompoundConvexHull => shape_settings.shape = .{ .ModelCompoundConvexHull = entity.model.? },
//             }
//         }
//     }
//
//     const sl = imui.push_layout(.Y, key ++ .{@src()});
//     if (imui.get_widget(sl)) |sl_widget| {
//         sl_widget.semantic_size[0].kind = .ParentPercentage;
//         sl_widget.semantic_size[0].value = 1.0;
//         sl_widget.padding_px = .{
//             .left = EntityEditorTabWidth,
//         };
//         sl_widget.children_gap = 5;
//     }
//
//     switch (shape_settings.shape) {
//         .Capsule => |*c| {
//             labeled_number_slider("radius:", &c.radius, key ++ .{@src()});
//             var height = c.half_height * 2.0;
//             labeled_number_slider("height:", &height, key ++ .{@src()});
//             c.half_height = height * 0.5;
//         },
//         .Sphere => |*s| {
//             labeled_number_slider("radius:", &s.radius, key ++ .{@src()});
//         },
//         .Box => |*b| {
//             labeled_number_slider("width:", &b.width, key ++ .{@src()});
//             labeled_number_slider("height:", &b.height, key ++ .{@src()});
//             labeled_number_slider("depth:", &b.depth, key ++ .{@src()});
//         },
//         .ModelCompoundConvexHull => |_| {
//         },
//     }
//
//     imui.pop_layout(); // sl
// }

fn labeled_number_slider(
    text: []const u8, 
    value: *f32, 
    key: anytype
) void {
    const ll = eng.get().imui.push_layout(.X, key ++ .{@src()});
    if (eng.get().imui.get_widget(ll)) |ll_widget| {
        ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        ll_widget.children_gap = 4;
    }
    defer eng.get().imui.pop_layout();

    const label = eng.get().imui.label(text);
    if (eng.get().imui.get_widget(label.id)) |label_widget| {
        label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable_percent = 0.0 };
    }
    _ = eng.get().imui.number_slider(value, .{}, key ++ .{@src()});
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

        const b = imui.button(v.name, key ++ .{@src(), idx});
        if (b.clicked) {
           try data.set_selected_name(v.name);
        }
    }

    const create_new_button = imui.button("create new", key ++ .{@src()});
    if (create_new_button.clicked) {
        std.log.info("should create new scene...", .{});
    }

    _ = imui.label(try std.fmt.allocPrint(eng.get().frame_allocator, "Scene to load: '{s}'", .{ data.selected_name orelse "None" }));

    {
        _ = imui.push_layout(.X, key ++ .{@src()});
        defer imui.pop_layout();

        const load_button = imui.button("Load", key ++ .{@src()});
        if (load_button.clicked) {
            if (data.selected_name) |name| {
                // Remove all existing entities
                for (eng.get().entities.list.data.items, 0..) |*it, i| {
                    if (it.item_data) |_| {
                        eng.get().entities.remove_entity(GenerationalIndex{.index = i, .generation = it.generation}) catch unreachable;
                    }
                }

                // Create new entities and set scene name
                try create_scene_entities(name);
                try self.set_loaded_scene_name(name);

                // close the load scene popup
                self.load_scene_popup_is_open = false;
                try data.set_selected_name(null);
            }
        }

        const cancel_button = imui.button("Cancel", key ++ .{@src()});
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
                sr.Serializable(eng.entity.EntityDescriptor),
                arena.allocator(),
                ent_str,
                .{ .ignore_unknown_fields = true, }
            ) catch |err| {
                std.log.err("Failed to parse file {s}: {}", .{ entry.name, err });
                continue;
            };

            const ent = sr.deserialize(eng.entity.EntityDescriptor, arena.allocator(), ent_s) catch |err| {
                std.log.err("Failed to deserialize entity {s}: {}", .{ entry.name, err });
                continue;
            };

            const loaded_entity = eng.get().entities.new_entity(ent) catch |err| {
                std.log.err("Failed to create entity {s}: {}", .{ entry.name, err });
                continue;
            };
            std.log.info("Loaded entity: {}", .{eng.get().entities.get(loaded_entity).?});
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

    var it = eng.get().entities.list.iterator();

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

        const entity_s = sr.serialize(eng.entity.EntityDescriptor, arena.allocator(), entity_descriptor) catch |err| {
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
