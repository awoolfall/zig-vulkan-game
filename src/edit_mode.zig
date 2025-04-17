const Self = @This();
const std = @import("std");

const en = @import("engine");
const engine = en.engine;
const gfx = en.gfx;

const Gizmo = @import("gizmo/gizmo.zig");
const SelectionTextures = @import("selection_textures.zig");
const pe = @import("particle_editor.zig");

const zm = en.zmath;
const sr = en.serialize;
const assets = en.assets;
const KeyCode = en.input.KeyCode;
const EntityDescriptor = en.Engine.EntityDescriptor;
const Transform = en.Transform;
const Camera = en.camera.Camera;
const Imui = en.ui.Imui;
const GenerationalIndex = en.gen.GenerationalIndex;

editor_camera: Camera,
gizmo: Gizmo,
entity_editor_ui_data: EntityEditorUiData,
selected_entity: ?GenerationalIndex = null,

file_dropdown_open: bool = false,
edit_dropdown_open: bool = false,

pub fn deinit(self: *Self) void {
    self.entity_editor_ui_data.deinit();
    self.gizmo.deinit();
}

pub fn init() !Self {
    return Self {
        .gizmo = try Gizmo.init(engine().general_allocator.allocator(), &engine().gfx),
        .entity_editor_ui_data = try EntityEditorUiData.init(engine().general_allocator.allocator()),
        .editor_camera = Camera {
            .field_of_view_y = Camera.horizontal_to_vertical_fov(90.0, engine().gfx.swapchain_aspect()),
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

pub fn update(self: *Self, selection_textures: *const SelectionTextures) !void {
    self.editor_camera.fly_camera_update(&engine().window, &engine().input, &engine().time);

    // new entity button
    if (!engine().imui.has_focus() and engine().input.get_key_down(KeyCode.E)) {
        self.create_new_entity();
    }

    // delete entity button
    if (!engine().imui.has_focus() and engine().input.get_key_down(KeyCode.Delete)) {
        self.remove_selected_entity();
    }

    if (!engine().imui.has_focus() and engine().input.get_key_down(KeyCode.MouseLeft) and engine().input.get_key(KeyCode.Shift)) {
        const selection_entity_id = selection_textures.get_value_at_position(@intCast(engine().input.cursor_position[0]), @intCast(engine().input.cursor_position[1]), &engine().gfx) catch |err| {
            std.log.err("cannot get value at position: {}", .{err});
            return;
        };

        if (selection_entity_id == 0) {
            self.selected_entity = null;
        } else if (self.selected_entity != null and self.selected_entity.?.index == selection_entity_id) {
            self.selected_entity = null;
        } else {
            const entity = engine().entities.get_dont_check_generation(selection_entity_id);
            if (entity) |ent| {
                std.log.info("entity name: {s}", .{ent.name orelse "unnamed"});
                self.selected_entity = .{
                    .index = selection_entity_id,
                    .generation = engine().entities.list.data.items[selection_entity_id].generation,
                };
                self.entity_editor_ui_data.inited = false;
            } else {
                std.log.info("entity not found!", .{});
            }
        }
    }

    const imui = &engine().imui;

    self.entity_editor_ui(&self.entity_editor_ui_data, .{@src()});
    
    // top bar UI
    const top_bar_background = imui.push_layout(.X, .{@src()});
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

    const l = imui.label("Edit Mode");
    if (imui.get_widget(l.id)) |label_widget| {
        label_widget.anchor = .{ 0.5, 0.5 };
        label_widget.pivot = .{ 0.5, 0.5 };
    }

    const items_layout = imui.push_layout(.X, .{@src()});
    if (imui.get_widget(items_layout)) |ilw| {
        ilw.children_gap = 4;
    }

    {
        const file_button = imui.button("File", .{@src()});
        if (imui.get_widget(file_button.id.box)) |file_widget| {
            file_widget.background_colour = zm.f32x4s(0.0);
            file_widget.border_width_px = 0;
            file_widget.padding_px = .{
                .top = 5,
                .bottom = 5,
                .left = 10,
                .right = 10,
            };
        }
        if (imui.get_widget(file_button.id.text)) |text_widget| {
            text_widget.text_content.?.colour = imui.palette().text_dark;
        }
        if (file_button.clicked) {
            self.file_dropdown_open = !self.file_dropdown_open;
        }
        defer {
            if (!file_button.clicked) {
                if (engine().input.get_key_down(KeyCode.MouseLeft)) {
                    self.file_dropdown_open = false;
                }
            }
        }

        file_blk: {
            if (self.file_dropdown_open) {
                const file_lfw = imui.get_widget_from_last_frame(file_button.id.box) orelse break :file_blk;
                const file_lfw_rect = file_lfw.computed.rect();
                const file_dropdown = imui.push_priority_floating_layout(.Y, @floatFromInt(file_lfw_rect.left), @floatFromInt(file_lfw_rect.top + file_lfw_rect.height), .{@src()});
                if (imui.get_widget(file_dropdown)) |file_dropdown_widget| {
                    file_dropdown_widget.flags.render = true;
                    file_dropdown_widget.background_colour = imui.palette().background;
                }
                defer imui.pop_layout();

                const save_button = imui.badge("Save Scene", .{@src()});
                if (save_button.clicked) {
                    save_entities_to_scene("scene") catch |err| {
                        std.log.err("Failed to save scene: {}", .{err});
                    };
                    std.log.debug("saved!", .{});
                }
                const load_button = imui.badge("Load Scene", .{@src()});
                if (load_button.clicked) {
                    for (engine().entities.list.data.items, 0..) |*it, idx| {
                        if (it.item_data) |_| {
                            engine().entities.remove_entity(GenerationalIndex{.index = idx, .generation = it.generation}) catch unreachable;
                        }
                    }
                    create_scene_entities("scene") catch |err| {
                        std.log.err("Failed to load scene: {}", .{err});
                    };
                    std.log.debug("loaded!", .{});
                }
            }
        }
    }

    {
        const edit_button = imui.button("Edit", .{@src()});
        if (imui.get_widget(edit_button.id.box)) |edit_widget| {
            edit_widget.background_colour = zm.f32x4s(0.0);
            edit_widget.border_width_px = 0;
            edit_widget.padding_px = .{
                .top = 5,
                .bottom = 5,
                .left = 10,
                .right = 10,
            };
        }
        if (imui.get_widget(edit_button.id.text)) |text_widget| {
            text_widget.text_content.?.colour = imui.palette().text_dark;
        }
        if (edit_button.clicked) {
            self.edit_dropdown_open = !self.edit_dropdown_open;
        }
        defer {
            if (!edit_button.clicked) {
                if (engine().input.get_key_down(KeyCode.MouseLeft)) {
                    self.edit_dropdown_open = false;
                }
            }
        }

        edit_blk: {
            if (self.edit_dropdown_open) {
                const edit_lfw = imui.get_widget_from_last_frame(edit_button.id.box) orelse break :edit_blk;
                const edit_lfw_rect = edit_lfw.computed.rect();
                const edit_dropdown = imui.push_priority_floating_layout(.Y, @floatFromInt(edit_lfw_rect.left), @floatFromInt(edit_lfw_rect.top + edit_lfw_rect.height), .{@src()});
                if (imui.get_widget(edit_dropdown)) |edit_dropdown_widget| {
                    edit_dropdown_widget.flags.render = true;
                    edit_dropdown_widget.background_colour = imui.palette().background;
                }
                defer imui.pop_layout();

                const new_button = imui.badge("New Entity", .{@src()});
                if (new_button.clicked) {
                    self.create_new_entity();
                }

                const delete_button = imui.badge("Delete Entity", .{@src()});
                if (delete_button.clicked) {
                    self.remove_selected_entity();
                }
            }
        }
    }

    imui.pop_layout();
    imui.pop_layout();
}

pub fn render(self: *Self, camera_data_buffer: *const gfx.Buffer, rtv: *const gfx.RenderTargetView, dsv: *const gfx.DepthStencilView) !void {
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
            self.gizmo.update(&entity.transform, zm.inverse(self.editor_camera.generate_perspective_matrix(engine().gfx.swapchain_aspect())), zm.inverse(self.editor_camera.transform.generate_view_matrix()));
            self.gizmo.render(&entity.transform, camera_data_buffer, rtv, dsv, &self.editor_camera);
        } 
    }
}

fn create_new_entity(self: *Self) void {
    _ = engine().entities.new_entity(EntityDescriptor {
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

fn remove_selected_entity(self: *Self) void {
    if (self.selected_entity) |selected_entity| {
        engine().entities.remove_entity(selected_entity) catch |err| {
            std.log.err("Failed to remove entity: {}", .{err});
        };
        self.selected_entity = null;
    }
}

const EntityEditorUiData = struct {
    arena: std.heap.ArenaAllocator,
    inited: bool = false,
    position: [2]f32 = .{ -10.0, 10.0 },

    transform_checkbox: bool = false,
    name_edit_data: Imui.TextInputState,
    model_combobox_data: Imui.ComboBoxData,

    physics_checkbox: bool = false,
    physics_combobox_data: Imui.ComboBoxData,
    shape_combobox_data: Imui.ComboBoxData,
    running_physics_desc: ?en.entity.PhysicsOptionsDescriptor = null,

    particle_checkbox: bool = false,
    particle_editor_data: pe.ParticleEditorData,
    particle_position: [2]f32 = .{ 0.0, 0.0 },

    pub fn deinit(self: *EntityEditorUiData) void {
        self.arena.deinit();
        self.name_edit_data.deinit();
        self.particle_editor_data.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !EntityEditorUiData {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        // generate model option names from asset packs
        var model_names = std.ArrayList([]u8).init(alloc);
        defer model_names.deinit();

        var asset_packs_iter = engine().asset_manager.loaded_asset_packs.iterator();
        while (asset_packs_iter.next()) |pack| {
            var models_iter = pack.models.keyIterator();
            while (models_iter.next()) |k| {
                try model_names.append(try std.fmt.allocPrint(arena.allocator(), "{s}|{s}", .{pack.unique_name, pack.get_asset_name(k.*).?}));
            }
        }

        const options = arena.allocator().alloc([]u8, model_names.items.len) catch unreachable;
        for (model_names.items, 0..) |name, i| {
            options[i] = name;
        }

        // generate physics option names from enum
        const physics_options_fields = @typeInfo(en.entity.PhysicsOptionsEnum).@"enum".fields;
        const physics_option_names = arena.allocator().alloc([]const u8, physics_options_fields.len) catch unreachable;
        inline for (physics_options_fields, 0..) |field, field_idx| {
            physics_option_names[field_idx] = field.name;
        }

        const physics_combobox_data = Imui.ComboBoxData {
            .default_text = "None",
            .can_be_default = true,
            .options = physics_option_names,
        };

        // generate shape option names from asset packs
        const shape_options_fields = @typeInfo(en.physics.ShapeSettingsEnum).@"enum".fields;
        const shape_option_names = arena.allocator().alloc([]const u8, shape_options_fields.len) catch unreachable;
        inline for (shape_options_fields, 0..) |field, field_idx| {
            shape_option_names[field_idx] = field.name;
        }

        const shape_combobox_data = Imui.ComboBoxData {
            .default_text = "",
            .can_be_default = false,
            .options = shape_option_names,
        };

        const particle_editor_data = pe.ParticleEditorData.init(engine().general_allocator.allocator());
        errdefer particle_editor_data.deinit();

        return EntityEditorUiData {
            .arena = arena,
            .model_combobox_data = Imui.ComboBoxData {
                .default_text = "None",
                .options = options,
            },
            .name_edit_data = Imui.TextInputState.init(engine().general_allocator.allocator()),
            .physics_combobox_data = physics_combobox_data,
            .shape_combobox_data = shape_combobox_data,
            .particle_editor_data = particle_editor_data,
        };
    }

    pub fn reinit(self: *EntityEditorUiData, entity: *en.entity.EntitySuperStruct) void {
        defer self.inited = true;

        var arena = std.heap.ArenaAllocator.init(engine().frame_allocator);
        defer arena.deinit();

        self.particle_editor_data.reinit(entity);
        self.particle_position = .{
            @as(f32, @floatFromInt(en.engine().gfx.swapchain_size.width)) * 0.5,
            @as(f32, @floatFromInt(en.engine().gfx.swapchain_size.height)) * 0.5,
        };

        // set name text
        self.name_edit_data.text.clearRetainingCapacity();
        self.name_edit_data.text.appendSlice(entity.name orelse "unnamed") catch unreachable;
        self.name_edit_data.cursor = self.name_edit_data.text.items.len;
        self.name_edit_data.mark = self.name_edit_data.text.items.len;

        // set model text
        const model_text = if (entity.model) |mid| sr.serialize(assets.ModelAssetId, arena.allocator(), mid) catch unreachable else "None";
        self.model_combobox_data.selected_index = null;
        for (self.model_combobox_data.options, 0..) |option, i| {
            if (std.mem.eql(u8, option, model_text)) {
                self.model_combobox_data.selected_index = i;
                break;
            }
        }
        _ = arena.reset(.retain_capacity);

        // set physics descriptor
        if (entity.physics) |*physics| {
            self.running_physics_desc = physics.descriptor();
            self.physics_combobox_data.selected_index = @intFromEnum(self.running_physics_desc.?);
        } else {
            self.running_physics_desc = null;
            self.physics_combobox_data.selected_index = null;
        }
    }
};

fn set_background_widget_layout(background_widget: *Imui.Widget) void {
    const imui = &engine().imui;

    background_widget.semantic_size[0].minimum_pixel_size = 350;
    background_widget.flags.clickable = true;
    background_widget.flags.render = true;
    background_widget.flags.hover_effect = false;
    background_widget.background_colour = imui.palette().background;
    background_widget.border_colour = imui.palette().border;
    background_widget.border_width_px = 2;
    background_widget.padding_px = .{
        .left = 10,
        .right = 10,
        .top = 10,
        .bottom = 10,
    };
    background_widget.corner_radii_px = .{
        .top_left = 10,
        .top_right = 10,
        .bottom_left = 10,
        .bottom_right = 10,
    };
    background_widget.children_gap = 5;
}

const EntityEditorTabWidth = 10;
fn entity_editor_ui(
    self: *Self, 
    data: *EntityEditorUiData,
    key: anytype,
) void {
    const imui = &engine().imui;
    if (self.selected_entity == null) return;
    const entity = engine().entities.get(self.selected_entity.?) orelse return;
    
    var arena = std.heap.ArenaAllocator.init(engine().frame_allocator);
    defer arena.deinit();

    if (!data.inited) {
        data.reinit(entity);
    }

    const background_box = imui.push_floating_layout(.Y, data.position[0], data.position[1], key ++ .{@src()});
    defer imui.pop_layout();
    if (imui.get_widget(background_box)) |background_widget| {
        set_background_widget_layout(background_widget);

        // origin is top right
        background_widget.anchor = .{ 1.0, 0.0 };
        background_widget.pivot = .{ 1.0, 0.0 };
    }
    if (imui.generate_widget_signals(background_box).dragged) {
        data.position[0] += engine().input.mouse_delta[0];
        data.position[1] += engine().input.mouse_delta[1];
    }

    const entity_editor_title_text = imui.label("Entity Editor");
    if (imui.get_widget(entity_editor_title_text.id)) |entity_editor_title_widget| {
        entity_editor_title_widget.anchor = .{ 0.5, 0.5 };
        entity_editor_title_widget.pivot = .{ 0.5, 0.5 };
    }
    _ = imui.checkbox(&entity.should_serialize, "should serialize", .{@src()});

    {
        const ll = imui.push_layout(.X, .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        const labell = imui.label("name:");
        if (imui.get_widget(labell.id)) |label_widget| {
            label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable_percent = 0.0 };
        }
        const name_edit = imui.line_edit(&data.name_edit_data, .{@src()});
        // if name line edit has changed then update the entity's name
        if (name_edit.data_changed) {
            if (entity.name) |_| {
                engine().general_allocator.allocator().free(entity.name.?);
                entity.name = std.fmt.allocPrint(engine().general_allocator.allocator(), "{s}", .{data.name_edit_data.text.items}) catch unreachable;
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
        const model_combobox = imui.combobox(&data.model_combobox_data, .{@src()});
        if (model_combobox.data_changed) {
            if (data.model_combobox_data.selected_index) |si| {
                if (sr.deserialize(assets.ModelAssetId, arena.allocator(), data.model_combobox_data.options[si])) |model_id| {
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

    _ = imui.collapsible(&data.transform_checkbox, "Transform", .{@src()});
    if (data.transform_checkbox) {
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
    _ = imui.collapsible(&data.physics_checkbox, "Physics", key ++ .{@src()});
    if (data.physics_checkbox) {
        const physics_button = imui.badge("Set Physics", key ++ .{@src()});
        if (physics_button.clicked) {
            if (data.physics_combobox_data.selected_index) |_| {
                entity.set_physics(self.selected_entity.?, data.running_physics_desc.?, &engine().physics) catch unreachable;
            } else {
                entity.remove_physics(&engine().physics);
            }
        }

        data.physics_combobox_data.selected_index = if (data.running_physics_desc) |d| @intFromEnum(d) else null;
        const physics_combobox = imui.combobox(&data.physics_combobox_data, key ++ .{@src()});
        if (physics_combobox.data_changed) {
            if (data.physics_combobox_data.selected_index) |si| {
                switch (@as(en.entity.PhysicsOptionsEnum, @enumFromInt(si))) {
                    .Body => data.running_physics_desc = .{ .Body = .{} },
                    .Character => data.running_physics_desc = .{ .Character = .{} },
                    .CharacterVirtual => data.running_physics_desc = .{ .CharacterVirtual = .{} },
                }
            }
        }
        if (data.physics_combobox_data.selected_index != null) {
            const transform_layout = imui.push_layout(.Y, key ++ .{@src()});
            if (imui.get_widget(transform_layout)) |transform_layout_widget| {
                transform_layout_widget.semantic_size[0].kind = .ParentPercentage;
                transform_layout_widget.semantic_size[0].value = 1.0;
                transform_layout_widget.children_gap = 5;
                transform_layout_widget.padding_px = .{
                    .left = EntityEditorTabWidth,
                };
            }
            defer imui.pop_layout();

            if (data.running_physics_desc) |*running_physics_desc| {
                switch (running_physics_desc.*) {
                    .Body => |*b| {
                        physics_shape_editor_ui(entity, &b.settings, data, key ++ .{@src()});
                        _ = imui.checkbox(&b.is_sensor, "is sensor", key ++ .{@src()});
                        _ = imui.checkbox(&b.is_static, "is static", key ++ .{@src()});
                    },
                    .Character => |_| {
                        _ = imui.label("is character");
                    },
                    .CharacterVirtual => |_| {
                        _ = imui.label("is virtual character");
                    },
                }
            }
        }
    }

    _ = imui.collapsible(&data.particle_checkbox, "Particle System", key ++ .{@src()});
    if (data.particle_checkbox) {
        const background = imui.push_floating_layout(.Y, data.particle_position[0], data.particle_position[1], key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(background)) |background_widget| {
            set_background_widget_layout(background_widget);
        }

        if (imui.generate_widget_signals(background).dragged) {
            data.particle_position[0] += engine().input.mouse_delta[0];
            data.particle_position[1] += engine().input.mouse_delta[1];
        }

        pe.particle_editor(&data.particle_editor_data, entity, key ++ .{@src()});
    }
}

fn physics_shape_editor_ui(
    entity: *en.entity.EntitySuperStruct,
    shape_settings: *en.physics.ShapeSettings, 
    data: *EntityEditorUiData, 
    key: anytype
) void {
    const imui = &engine().imui;
    data.shape_combobox_data.selected_index = @intFromEnum(shape_settings.shape);
    const shape_combobox = imui.combobox(&data.shape_combobox_data, key ++ .{@src()});
    if (shape_combobox.data_changed) {
        if (data.shape_combobox_data.selected_index) |si| {
            switch (@as(en.physics.ShapeSettingsEnum, @enumFromInt(si))) {
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
            labeled_number_slider("radius:", &c.radius, key ++ .{@src()});
            var height = c.half_height * 2.0;
            labeled_number_slider("height:", &height, key ++ .{@src()});
            c.half_height = height * 0.5;
        },
        .Sphere => |*s| {
            labeled_number_slider("radius:", &s.radius, key ++ .{@src()});
        },
        .Box => |*b| {
            labeled_number_slider("width:", &b.width, key ++ .{@src()});
            labeled_number_slider("height:", &b.height, key ++ .{@src()});
            labeled_number_slider("depth:", &b.depth, key ++ .{@src()});
        },
        .ModelCompoundConvexHull => |_| {
        },
    }

    imui.pop_layout(); // sl
}

fn labeled_number_slider(
    text: []const u8, 
    value: *f32, 
    key: anytype
) void {
    const ll = engine().imui.push_layout(.X, key ++ .{@src()});
    if (engine().imui.get_widget(ll)) |ll_widget| {
        ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        ll_widget.children_gap = 4;
    }
    defer engine().imui.pop_layout();

    const label = engine().imui.label(text);
    if (engine().imui.get_widget(label.id)) |label_widget| {
        label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable_percent = 0.0 };
    }
    _ = engine().imui.number_slider(value, .{}, key ++ .{@src()});
}

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
                sr.Serializable(en.entity.EntityDescriptor),
                arena.allocator(),
                ent_str,
                .{ .ignore_unknown_fields = true, }
            ) catch |err| {
                std.log.err("Failed to parse file {s}: {}", .{ entry.name, err });
                continue;
            };

            const ent = sr.deserialize(en.entity.EntityDescriptor, arena.allocator(), ent_s) catch |err| {
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

        const entity_s = sr.serialize(en.entity.EntityDescriptor, arena.allocator(), entity_descriptor) catch |err| {
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
