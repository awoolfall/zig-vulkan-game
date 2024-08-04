const std = @import("std");
const engine = @import("engine");
const app = @import("app.zig");

pub fn main() !void {
    try app.Engine.run();
}

