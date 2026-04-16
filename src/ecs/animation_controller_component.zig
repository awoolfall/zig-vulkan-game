const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

pub const COMPONENT_UUID = "9c14aaea-39b5-4c05-9504-a48577f32c94";
pub const COMPONENT_NAME = "Animation Controller";

const Self = @This();

anim_controller: eng.animation_controller.AnimController,

pub fn deinit(self: *Self) void {
    self.anim_controller.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const anim_controller = try eng.animation_controller.AnimController.init(alloc);
    errdefer anim_controller.deinit();

    return .{
        .anim_controller = anim_controller,
    };
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try object.put("anim_controller", try sr.serialize_value(eng.animation_controller.AnimController, alloc, self.anim_controller));
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    const anim_controller = try sr.deserialize_value(eng.animation_controller.AnimController, alloc, object.get("anim_controller"));
    errdefer anim_controller.deinit();

    return Self {
        .anim_controller = anim_controller,
    };
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    _ = entity;

    _ = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    {
        // TODO
        _ = component;
    }
}
