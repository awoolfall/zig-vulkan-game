const std = @import("std");
const eng = @import("engine");
const sr = eng.serialize;

const OceanSettings = @import("ocean_renderer.zig").OceanSettings;

pub const RESOURCE_NAME = "Ocean";
pub const RESOURCE_UUID = "139f4460-59c7-4e6e-b03c-a8ab108306d2";

const Self = @This();

ocean_settings: OceanSettings,

pub fn deinit(self: *Self) void {
    _ = self;
}

pub fn init() !Self {
    return Self{
        .ocean_settings = .{ .amplitude = 0.06, .wind = .{ 4.0, 0.0 } },
    };
}

pub fn serialize(self: *const Self, alloc: std.mem.Allocator, object: *std.json.ObjectMap) !void {
    try sr.serialize_object_value(alloc, object, OceanSettings, "settings", self.ocean_settings);
}

pub fn deserialize(self: *Self, object: *const std.json.ObjectMap) !void {
    const alloc = eng.get().general_allocator;

    self.ocean_settings = try sr.deserialize_object_value(alloc, object, OceanSettings, "settings") orelse .{ .amplitude = 0.06, .wind = .{ 4.0, 0.0 } };
}

pub fn editor_ui(self: *Self, imui: *eng.Imui) void {
    {
        _ = imui.push_form_layout_item(.{@src()});
        defer imui.pop_layout();
        _ = eng.Imui.widgets.label.create(imui, "amplitude: ");
        _ = eng.Imui.widgets.number_slider.create(imui, &self.ocean_settings.amplitude, .{ .scale = 0.01 }, .{@src()});
    }
    {
        _ = imui.push_form_layout_item(.{@src()});
        defer imui.pop_layout();
        _ = eng.Imui.widgets.label.create(imui, "wind: ");
        _ = eng.Imui.widgets.number_slider.create(imui, @as([]f32, &self.ocean_settings.wind), .{ .scale = 0.01 }, .{@src()});
    }
}
