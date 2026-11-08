const std = @import("std");

pub const WindowEvent = union(enum) {
    resized: WindowSize,
    events_cleared: void,
    lost_focus: void,
    gained_focus: void,
    key_down: KeyEvent,
    key_repeat: KeyEvent,
    key_up: KeyEvent,
    char: CharEvent,
    cursor_moved: CursorMoveEvent,
    raw_mouse_moved: RawMouseMoveEvent,
    dropped_files: DroppedFilesEvent,
    window_requested_close: u32,
    window_closed: u32,
    window_created: WindowCreatedEvent,
};

pub const Rect = extern struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const WindowSize = extern struct {
    width: i32,
    height: i32,
};

pub const KeyEvent = extern struct {
    keycode: @import("../input/keycode.zig").KeyCode,
    repeat_count: u16,
    scan_code: u16,
};

pub const CharEvent = extern struct {
    utf8_char_seq: [2:0]u8,
    utf8_char_len: usize,
    repeat_count: u16,
    scan_code: u16,
};

pub const CursorMoveEvent = extern struct {
    x_coord: i32,
    y_coord: i32,
};

pub const RawMouseMoveEvent = extern struct {
    x_delta: i32,
    y_delta: i32,
};

pub const WindowCreatedEvent = extern struct {
    id: u32,
    window: @import("os.zig").Window.WindowIdentifierExtern,
};

pub const DroppedFilesEvent = extern struct {
    paths: [*]const [*:0]const u8,
    num_paths: u32,

    pub fn deinit(self: DroppedFilesEvent, alloc: std.mem.Allocator) void {
        for (0..self.num_paths) |idx| {
            alloc.free(std.mem.span(self.paths[idx]));
        }
        alloc.free(self.paths[0..self.num_paths]);
    }
};
