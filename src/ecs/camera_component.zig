const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

pub const COMPONENT_UUID = "8b843394-9c75-4734-8d8b-edfff98536a5";
pub const COMPONENT_NAME = "Camera";

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
