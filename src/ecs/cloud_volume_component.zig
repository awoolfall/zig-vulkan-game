const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

pub const COMPONENT_UUID = "ffab0e05-4e47-4d11-9931-d8bbf6ec7daf";
pub const COMPONENT_NAME = "Cloud Volume";

const Self = @This();

int: u32 = 0,

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init(alloc: std.mem.Allocator) !Self {
    _ = alloc;
    return .{};
}

pub fn serialize(alloc: std.mem.Allocator, value: Self) !std.json.Value {
    var object = std.json.ObjectMap.init(alloc);
    errdefer object.deinit();

    try object.put("int", try sr.serialize_value(u32, alloc, value.int));

    return std.json.Value { .object = object };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    var component: Self = .{};
    const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

    component.int = try sr.deserialize_value(u32, alloc, object.get("int"));

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
