const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;
const zm = eng.zmath;
const StandardRenderer = @import("../render.zig");

pub const COMPONENT_UUID = "c9cb8354-6c2c-47ee-9d13-e9ef0a5e8ad5";
pub const COMPONENT_NAME = "Light";

const Self = @This();

light: StandardRenderer.Light,

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return .{
        .light = .{},
    };
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try object.put("light", try sr.serialize_value(StandardRenderer.Light, alloc, self.light));
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    const light = try sr.deserialize_value(StandardRenderer.Light, alloc, object.get("light"));

    return Self {
        .light = light,
    };
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
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
