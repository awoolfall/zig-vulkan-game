const std = @import("std");
const eng = @import("engine");
const builtin = @import("builtin");

// extern "game" fn run(engine: *en.Engine) void;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    var gpa, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        const check = debug_allocator.deinit();
        if (check != std.heap.Check.ok) {
            std.log.err("Debug Allocator leak check: {}", .{check});
        }
    };

    const engine = eng.Engine.init_engine(&gpa) orelse return error.FailedToInitEngine;
    defer engine.deinit();

    engine.run();
}

