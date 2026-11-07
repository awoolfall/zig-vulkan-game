const std = @import("std");
const eng = @import("self");
const zm = eng.zmath;
const Imui = eng.Imui;
const label = @import("label.zig");

pub const NumberSliderSettings = struct {
    scale: f32 = 0.01,
};

fn create_f32(imui: *Imui, value: *f32, settings: NumberSliderSettings, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const background = imui.push_layout(.X, key ++ .{@src()});
    defer imui.pop_layout();
    if (imui.get_widget(background)) |background_widget| {
        background_widget.semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true },
            Imui.SemanticSize{ .kind = .Pixels, .value = 16.0, .shrinkable = false },
        };
        background_widget.flags.render = true;
        background_widget.flags.hover_effect = false;
        background_widget.flags.clickable = true;
        background_widget.background_colour = imui.palette().muted;
        background_widget.border_colour = imui.palette().border;
        background_widget.border_width_px = .all(1);
        background_widget.corner_radii_px = .all(4);
        background_widget.padding_px = .all(4);
    }

    var text_buffer: [32]u8 = undefined;
    const text = label.create(imui, std.fmt.bufPrint(&text_buffer, "{d:.2}", .{value.*}) catch unreachable);
    if (imui.get_widget(text.id)) |text_widget| {
        _ = text_widget;
    }

    var background_signals = imui.generate_widget_signals(background);
    if (background_signals.dragged) {
        value.* += eng.get().input.get_mouse_delta()[0] * settings.scale;
        background_signals.data_changed = true;
    }

    return background_signals;
}

fn create_array_f32(imui: *Imui, value: []f32, settings: NumberSliderSettings, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    const background = imui.push_layout(.X, key ++ .{@src()});
    defer imui.pop_layout();
    if (imui.get_widget(background)) |w| {
        w.semantic_size = [2]Imui.SemanticSize{
            Imui.SemanticSize{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true },
            Imui.SemanticSize{ .kind = .ChildrenSize, .value = 1.0, .shrinkable = false },
        };
        w.children_gap = 2.0;
    }

    var signals: Imui.WidgetSignal(Imui.WidgetId) = undefined;
    for (value, 0..) |*v, idx| {
        const res = create_f32(imui, v, settings, key ++ .{ idx, @src() });

        if (idx == 0) {
            signals = res;
        } else {
            signals = eng.Imui.combine_signals(.{ signals, res }, res.id);
        }
    }

    return signals;
}

pub fn create(imui: *Imui, value: anytype, settings: NumberSliderSettings, key: anytype) Imui.WidgetSignal(Imui.WidgetId) {
    switch (@TypeOf(value)) {
        *f32 => return create_f32(imui, value, settings, key),
        []f32 => return create_array_f32(imui, value, settings, key),
        std.meta.Tuple(&[1]type{*f32}) => return create(imui, value.@"0", settings, key),
        std.meta.Tuple(&[2]type{ *f32, *f32 }) => return create(imui, &[2]f32{ value.@"0", value.@"1" }, settings, key),
        std.meta.Tuple(&[3]type{ *f32, *f32, *f32 }) => return create(imui, &[3]f32{ value.@"0", value.@"1", value.@"2" }, settings, key),
        std.meta.Tuple(&[4]type{ *f32, *f32, *f32, *f32 }) => return create(imui, &[4]f32{ value.@"0", value.@"1", value.@"2", value.@"3" }, settings, key),
        *zm.F32x4 => return create(imui, &value, settings, key),
        else => @compileError(@typeName(@TypeOf(value)) ++ " value type not supported by number_slider"),
    }
}
