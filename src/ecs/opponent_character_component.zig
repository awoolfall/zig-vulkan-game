const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

pub const COMPONENT_UUID = "0df56a31-d9a8-4656-9750-60f19a18c4a1";
pub const COMPONENT_NAME = "Opponent Character";

const Self = @This();

movement_speed: f32 = 4.0,

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

    _ = value;

    return std.json.Value { .object = object };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    const component: Self = .{};
    const object = switch (value) { .object => |obj| obj, else => return error.InvalidType, };

    _ = alloc;
    _ = object;

    return component;
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    {
        // TODO
        _ = entity;
        _ = component;
    }
}
