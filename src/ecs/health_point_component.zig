const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

pub const COMPONENT_UUID = "8825045a-08cb-4c4f-88ed-9440c58a4781";
pub const COMPONENT_NAME = "Health Points";

const Self = @This();

health_points: i32 = 0,

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return .{};
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try object.put("health_points", try sr.serialize_value(i32, alloc, self.health_points));
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    var component: Self = .{};

    component.health_points = try sr.deserialize_value(i32, alloc, object.get("health_points"));

    return component;
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
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
