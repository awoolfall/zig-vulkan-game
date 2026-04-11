const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const sr = eng.serialize;
const StandardRenderer = @import("render.zig");
const Terrain = @import("terrain/terrain.zig");

pub const HealthPointComponent = struct {
    health_points: i32 = 0,

    pub fn deinit(self: *HealthPointComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !HealthPointComponent {
        _ = alloc;
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: HealthPointComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("health_points", try sr.serialize_value(i32, alloc, value.health_points));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !HealthPointComponent {
        var component: HealthPointComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.health_points = try sr.deserialize_value(i32, alloc, object.get("health_points"));

        return component;
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *HealthPointComponent, key: anytype) !void {
        _ = entity;

        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            _ = imui.push_form_layout_item(key ++ .{@src()});
            defer imui.pop_layout();

            _ = eng.ui.widgets.label.create(imui, "health points: ");
            var float_health_points: f32 = @floatFromInt(component.health_points);
            const hp_slider = eng.ui.widgets.number_slider.create(imui, &float_health_points, .{ .scale = 1.0, }, key ++ .{@src()});
            if (hp_slider.data_changed) {
                component.health_points = @intFromFloat(float_health_points);
            }
        }
    }
};

pub const AnimControllerComponent = struct {
    anim_controller: eng.animation.AnimController,

    pub fn deinit(self: *AnimControllerComponent) void {
        self.anim_controller.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !AnimControllerComponent {
        const anim_controller = try eng.animation.AnimController.init(alloc);
        errdefer anim_controller.deinit();

        return .{
            .anim_controller = anim_controller,
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: AnimControllerComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("anim_controller", try sr.serialize_value(eng.animation.AnimController, alloc, value.anim_controller));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !AnimControllerComponent {
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        const anim_controller = try sr.deserialize_value(eng.animation.AnimController, alloc, object.get("anim_controller"));
        errdefer anim_controller.deinit();

        return AnimControllerComponent {
            .anim_controller = anim_controller,
        };
    }
    
    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *AnimControllerComponent, key: anytype) !void {
        _ = entity;

        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};

pub const ParticleSystemComponent = struct {
    particle_system: eng.particles.ParticleSystem,

    pub fn deinit(self: *ParticleSystemComponent) void {
        self.particle_system.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !ParticleSystemComponent {
        const particle_system = try eng.particles.ParticleSystem.init(alloc, .{});
        errdefer particle_system.deinit();

        return .{
            .particle_system = particle_system,
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: ParticleSystemComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("particle_system_settings", try sr.serialize_value(eng.particles.ParticleSystemSettings, alloc, value.particle_system.settings));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !ParticleSystemComponent {
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        var particle_system_settings = try sr.deserialize_value(eng.particles.ParticleSystemSettings, alloc, object.get("particle_system_settings"));
        defer particle_system_settings.deinit(alloc);

        const particle_system = try eng.particles.ParticleSystem.init(alloc, particle_system_settings);
        errdefer particle_system.deinit();
        
        return ParticleSystemComponent {
            .particle_system = particle_system,
        };
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *ParticleSystemComponent, key: anytype) !void {
        _ = entity;

        _ = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        {
            // TODO
            _ = component;
        }
    }
};

pub const LightComponent = struct {
    light: StandardRenderer.Light,

    pub fn deinit(self: *LightComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !LightComponent {
        _ = alloc;
        return .{
            .light = .{},
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: LightComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("light", try sr.serialize_value(StandardRenderer.Light, alloc, value.light));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !LightComponent {
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        const light = try sr.deserialize_value(StandardRenderer.Light, alloc, object.get("light"));

        return LightComponent {
            .light = light,
        };
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *LightComponent, key: anytype) !void {
        _ = entity;

        const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(outer_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
            w.children_gap = 5.0;
        }

        const light_type_combobox = eng.ui.widgets.combobox.create(imui, key ++ .{@src()});
        const light_type_combobox_data, _ = imui.get_widget_data(eng.ui.widgets.combobox.ComboBoxState, light_type_combobox.id) catch unreachable;
        if (light_type_combobox.init) {
            light_type_combobox_data.can_be_default = false;

            const light_type_options_fields = @typeInfo(StandardRenderer.LightType).@"enum".fields;
            inline for (light_type_options_fields) |field| {
                light_type_combobox_data.append_option(imui.widget_allocator(), field.name) catch unreachable;
            }

            light_type_combobox_data.selected_index = @intFromEnum(component.light.light_type);
        }
        if (light_type_combobox.data_changed) {
            if (light_type_combobox_data.selected_index) |si| {
                component.light.light_type = @as(StandardRenderer.LightType, @enumFromInt(si));
            } else {
                std.log.warn("Huh?", .{});
            }
        }

        {
            _ = imui.push_form_layout_item(.{@src()});
            defer imui.pop_layout();

            _ = eng.ui.widgets.label.create(imui, "colour: ");
            
            // _ = imui.push_layout(.X, key ++ .{@src()});
            // defer imui.pop_layout();

            // if (imui.get_widget(container_layout)) |c| {
            //     c.semantic_size[0] = Imui.SemanticSize { .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0 };
            //     c.semantic_size[1] = Imui.SemanticSize { .kind = .Pixels, .value = 100.0, .shrinkable_percent = 0.0 };
            // }

            var colour: ?zm.F32x4 = component.light.colour;
            const colour_indicator_signals = eng.ui.widgets.colour_indicator.create(imui, &colour.?, key ++ .{@src()});
            const colour_indicator_data, _ = imui.get_widget_data(bool, colour_indicator_signals.id) catch unreachable;

            if (colour_indicator_signals.init) {
                colour_indicator_data.* = false;
            }

            if (colour_indicator_signals.clicked) {
                colour_indicator_data.* = !colour_indicator_data.*;
            }

            if (colour_indicator_data.*) {
                const picker_floating_layout = imui.push_floating_layout_with_priority(.Y, 10.0, 10.0, 100, key ++ .{@src()});
                defer imui.pop_layout();

                if (imui.get_widget(picker_floating_layout)) |w| {
                    set_background_widget_layout(w);
                    w.semantic_size[0].minimum_pixel_size = 350;
                    w.semantic_size[1].minimum_pixel_size = 350;
                }

                const picker_floating_position, _ = imui.get_widget_data([2]f32, picker_floating_layout) catch unreachable;
                imui.set_floating_layout_position(picker_floating_layout, picker_floating_position[0], picker_floating_position[1]);

                if (imui.generate_widget_signals(picker_floating_layout).dragged) {
                    picker_floating_position[0] += eng.get().input.mouse_delta[0];
                    picker_floating_position[1] += eng.get().input.mouse_delta[1];
                }

                _ = eng.ui.widgets.label.create(imui, "colour picker");
                const picker_signals = eng.ui.widgets.colour_picker.create(imui, &colour, key ++ .{@src()});
                if (picker_signals.data_changed) {
                    if (colour) |c| {
                        component.light.colour = c;
                    }
                }
            }
            //_ = Imui.widgets.colour_picker.create(imui, &colour, key ++ .{@src()});

            // _ = Imui.widgets.number_slider.create(imui, &light.colour[0], .{}, key ++ .{@src()});
            // _ = Imui.widgets.number_slider.create(imui, &light.colour[1], .{}, key ++ .{@src()});
            // _ = Imui.widgets.number_slider.create(imui, &light.colour[2], .{}, key ++ .{@src()});
        }

        create_form_number_slider("intensity:", &component.light.intensity, key ++ .{@src()});

        if (component.light.light_type == .Spot) {
            var umbra_degrees = std.math.radiansToDegrees(component.light.umbra);
            create_form_number_slider("umbra:", &umbra_degrees, key ++ .{@src()});
            component.light.umbra = std.math.degreesToRadians(umbra_degrees);

            var penumbra_degrees = std.math.radiansToDegrees(component.light.delta_penumbra);
            create_form_number_slider("delta penumbra:", &penumbra_degrees, key ++ .{@src()});
            component.light.delta_penumbra = std.math.degreesToRadians(penumbra_degrees);
        }
    }
};

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

fn create_form_number_slider(
    text: []const u8,
    value: *f32, 
    key: anytype
) void {
    const imui = &eng.get().imui;

    _ = imui.push_form_layout_item(key ++ .{@src()});
    defer imui.pop_layout();

    _ = eng.ui.widgets.label.create(imui, text);
    _ = eng.ui.widgets.number_slider.create(imui, value, .{}, key ++ .{@src()});
}

pub const TerrainComponent = struct {
    terrain: Terrain,

    pub fn deinit(self: *TerrainComponent) void {
        self.terrain.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) !TerrainComponent {
        const terrain = try Terrain.init(alloc);
        errdefer terrain.deinit();

        return .{
            .terrain = terrain,
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: TerrainComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("terrain", try sr.serialize_value(Terrain, alloc, value.terrain));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !TerrainComponent {
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        const terrain = try sr.deserialize_value(Terrain, alloc, object.get("terrain"));
        errdefer terrain.deinit();

        return TerrainComponent {
            .terrain = terrain,
        };
    }
    
    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *TerrainComponent, key: anytype) !void {
        const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(outer_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
            w.children_gap = 5.0;
        }

        component.terrain.editor_ui(entity, key ++ .{@src()});

        _ = eng.ui.widgets.line_edit.create(imui, .{ .allowed_character_set = .RealNumber, }, key ++ .{@src()});
    }
};

pub const CloudVolumeComponent = struct {
    int: u32 = 0,

    pub fn deinit(self: *CloudVolumeComponent) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !CloudVolumeComponent {
        _ = alloc;
        return .{};
    }

    pub fn serialize(alloc: std.mem.Allocator, value: CloudVolumeComponent) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("int", try sr.serialize_value(u32, alloc, value.int));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !CloudVolumeComponent {
        var component: CloudVolumeComponent = .{};
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.int = try sr.deserialize_value(u32, alloc, object.get("int"));

        return component;
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *CloudVolumeComponent, key: anytype) !void {
        _ = entity;

        const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(outer_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
            w.children_gap = 5.0;
        }

        {
            // TODO
            _ = component;
        }
    }
};

pub const CameraComponent = struct {
    const Self = @This();

    camera_data: eng.camera.Camera,

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !Self {
        _ = alloc;
        return .{
            .camera_data = .{
                .field_of_view_y = eng.camera.Camera.horizontal_to_vertical_fov(std.math.degreesToRadians(90.0), eng.get().gfx.swapchain_aspect()),
                .near_field = 0.3,
                .far_field = 10_000.0,
                .move_speed = 10.0,
                .mouse_sensitivity = 0.001,
                .max_orbit_distance = 10.0,
                .min_orbit_distance = 1.0,
                .orbit_distance = 5.0,
            }
        };
    }

    pub fn serialize(alloc: std.mem.Allocator, value: Self) !std.json.Value {
        var object = std.json.ObjectMap.init(alloc);
        errdefer object.deinit();

        try object.put("camera_data", try sr.serialize_value(eng.camera.Camera, alloc, value.camera_data));

        return std.json.Value { .object = object };
    }

    pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
        var component: Self = .{
            .camera_data = undefined,
        };
        const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

        component.camera_data = try sr.deserialize_value(eng.camera.Camera, alloc, object.get("camera_data"));

        return component;
    }

    pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
        _ = entity;

        const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
        defer imui.pop_layout();

        if (imui.get_widget(outer_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
            w.children_gap = 5.0;
        }

        {
            // TODO
            _ = component;
        }
    }
};
