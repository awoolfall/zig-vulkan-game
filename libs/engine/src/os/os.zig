const std = @import("std");

pub const Platform = switch (@import("builtin").os.tag) {
    .windows => @import("windows/windows.zig").WindowsPlatform,
    else => @compileError("Unsupported OS"),
};
pub const Window = Platform.Window;

pub const events = @import("window_events.zig");
pub const WindowEvent = events.WindowEvent;
pub const WindowEventExtern = @import("extern_events.zig").WindowEventExtern;
