const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;
const Terrain = @import("../terrain/terrain.zig");

pub const COMPONENT_UUID = "975179b1-08e5-4a76-8143-f297ef565edd";
pub const COMPONENT_NAME = "Terrain";

const Self = @This();

terrain: Terrain,

pub fn deinit(self: *Self) void {
    self.terrain.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const terrain = try Terrain.init(alloc);
    errdefer terrain.deinit();

    return .{
        .terrain = terrain,
    };
}

pub fn serialize(self: *Self, alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: *std.json.ObjectMap) !void {
    _ = entity;
    try object.put("terrain", try sr.serialize_value(Terrain, alloc, self.terrain));
}

pub fn deserialize(alloc: std.mem.Allocator, entity: eng.ecs.Entity, object: std.json.ObjectMap) !Self {
    _ = entity;
    const terrain = try sr.deserialize_value(Terrain, alloc, object.get("terrain"));
    errdefer terrain.deinit();

    return Self {
        .terrain = terrain,
    };
}

pub fn editor_ui(imui: *eng.ui, entity: eng.ecs.Entity, component: *Self, key: anytype) !void {
    const outer_layout = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(outer_layout)) |w| {
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false };
        w.children_gap = 5.0;
    }

    component.terrain.editor_ui(entity, key ++ .{@src()});

    _ = eng.ui.widgets.line_edit.create(imui, .{ .allowed_character_set = .RealNumber, }, key ++ .{@src()});
}
