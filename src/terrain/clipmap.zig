const std = @import("std");
const eng = @import("engine");
const gf = eng.gfx;

const Self = @This();

// TODO improve skirt transition. Reduce quad section size by 1 and improve rounding in shader so that clipmap levels dont overlap.
// TODO split clipmaps into segments https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry

vertices_buffer: gf.Buffer.Ref,
indices_buffer: gf.Buffer.Ref,
outer_ring_indices_count: u32,
full_ring_indices_count: u32,

pub fn deinit(self: *const Self) void {
    self.vertices_buffer.deinit();
    self.indices_buffer.deinit();
}

pub fn init(alloc: std.mem.Allocator, side_length: u32) !Self {
    const side_length_f32: f32 = @floatFromInt(side_length);
    const quad_vertices_count = (side_length + 1) * (side_length + 1);
    const quad_indices_count = side_length * side_length * 6;
    
    const skirt_segment_positions: [9][3]f32 = .{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
        
        .{ 0.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 2.0, 0.0, 1.0 },

        .{ 2.0, 0.0, 1.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 2.0, 0.0, 0.0 },
    };

    const quad_verts_a: [6][2]u32 = .{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 1, 0 },
        .{ 1, 1 },
        .{ 0, 1 },
    };
    const quad_verts_b: [6][2]u32 = .{
        .{ 0, 0 },
        .{ 1, 1 },
        .{ 0, 1 },
        .{ 1, 1 },
        .{ 0, 0 },
        .{ 1, 0 },
    };

    const num_skirt_segments_per_side = side_length / 2;
    
    const skirt_segment_vertices_count =
        (9 * num_skirt_segments_per_side * 4)   // edge skirt segment for each side
        + (6 * 4);                              // quad for each corner

    const vertices = try alloc.alloc([3]f32, quad_vertices_count + skirt_segment_vertices_count);
    defer alloc.free(vertices);
    var vertices_list = std.ArrayList([3]f32).initBuffer(vertices);

    const indices = try alloc.alloc(u32, quad_indices_count + skirt_segment_vertices_count);
    defer alloc.free(indices);
    var indices_list = std.ArrayList(u32).initBuffer(indices);

    // Add skirt vertices

    // top skirt
    for (0..num_skirt_segments_per_side) |i| {
        const base_position = [3]f32 { (@as(f32, @floatFromInt(i)) * 2.0) / side_length_f32, 0.0, 0.0 };
        var it = std.mem.reverseIterator(&skirt_segment_positions);
        while (it.next()) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] + p[0] / side_length_f32, base_position[1] + p[1], base_position[2] - p[2] / side_length_f32 });
        }
    }

    // bottom skirt
    for (0..num_skirt_segments_per_side) |i| {
        const base_position = [3]f32 { (@as(f32, @floatFromInt(i)) * 2.0) / side_length_f32, 0.0, 1.0 };
        for (skirt_segment_positions) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] + p[0] / side_length_f32, base_position[1] + p[1], base_position[2] + p[2] / side_length_f32 });
        }
    }

    // left skirt
    for (0..num_skirt_segments_per_side) |i| {
        const base_position = [3]f32 { 0.0, 0.0, (@as(f32, @floatFromInt(i)) * 2.0) / side_length_f32 };
        for (skirt_segment_positions) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] - p[2] / side_length_f32, base_position[1] + p[1], base_position[2] + p[0] / side_length_f32 });
        }
    }

    // right skirt
    for (0..num_skirt_segments_per_side) |i| {
        const base_position = [3]f32 { 1.0, 0.0, (@as(f32, @floatFromInt(i)) * 2.0) / side_length_f32 };
        var it = std.mem.reverseIterator(&skirt_segment_positions);
        while (it.next()) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] + p[2] / side_length_f32, base_position[1] + p[1], base_position[2] + p[0] / side_length_f32 });
        }
    }

    // top right quad
    {
        const base_position = [3]f32 { 1.0, 0.0, 0.0 };
        var it = std.mem.reverseIterator(&quad_verts_a);
        while (it.next()) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] + @as(f32, @floatFromInt(p[0])) / side_length_f32, base_position[1], base_position[2] - @as(f32, @floatFromInt(p[1])) / side_length_f32 });
        }
    }

    // bottom right quad
    {
        const base_position = [3]f32 { 1.0, 0.0, 1.0 };
        for (quad_verts_a) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] + @as(f32, @floatFromInt(p[0])) / side_length_f32, base_position[1], base_position[2] + @as(f32, @floatFromInt(p[1])) / side_length_f32 });
        }
    }

    // top left quad
    {
        const base_position = [3]f32 { 0.0, 0.0, 0.0 };
        for (quad_verts_a) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] - @as(f32, @floatFromInt(p[0])) / side_length_f32, base_position[1], base_position[2] - @as(f32, @floatFromInt(p[1])) / side_length_f32 });
        }
    }

    // bottom left quad
    {
        const base_position = [3]f32 { 0.0, 0.0, 1.0 };
        var it = std.mem.reverseIterator(&quad_verts_a);
        while (it.next()) |p| {
            try vertices_list.appendBounded([3]f32 { base_position[0] - @as(f32, @floatFromInt(p[0])) / side_length_f32, base_position[1], base_position[2] + @as(f32, @floatFromInt(p[1])) / side_length_f32 });
        }
    }

    const quad_base_vertex = vertices_list.items.len;

    for (0..skirt_segment_vertices_count) |i| {
        try indices_list.appendBounded(@intCast(i));
    }

    const quad_base_index = indices_list.items.len;

    for (0..(side_length + 1)) |i| {
        for (0..(side_length + 1)) |j| {
            vertices[quad_base_vertex + (i * (side_length + 1)) + j] = [3]f32 { @as(f32, @floatFromInt(i)) / side_length_f32, 0.0, @as(f32, @floatFromInt(j)) / side_length_f32 };
        }
    }

    const SIDE_LENGTH_ON_4 = side_length / 4;

    for (0..side_length) |i| {
        for (0..side_length) |j| {
            if (i >= SIDE_LENGTH_ON_4 and i < (3 * SIDE_LENGTH_ON_4) and j >= SIDE_LENGTH_ON_4 and j < (3 * SIDE_LENGTH_ON_4)) {
                continue;
            }
            for (0..6) |vti| {
                const quad_verts = (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast(quad_base_index + (i * (side_length + 1)) + j);
                try indices_list.appendBounded(base_index + (quad_verts[0] * (side_length + 1)) + quad_verts[1]);
            }
        }
    }

    const outer_ring_indices_count: u32 = @intCast(indices_list.items.len);

    for (SIDE_LENGTH_ON_4 .. (3 * SIDE_LENGTH_ON_4)) |i| {
        for (SIDE_LENGTH_ON_4 .. (3 * SIDE_LENGTH_ON_4)) |j| {
            for (0..6) |vti| {
                const quad_verts = (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast(quad_base_index + (i * (side_length + 1)) + j);
                try indices_list.appendBounded(base_index + (quad_verts[0] * (side_length + 1)) + quad_verts[1]);
            }
        }
    }

    const vertices_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(vertices),
        .{ .VertexBuffer = true, },
        .{}
    );
    errdefer vertices_buffer.deinit();

    const indices_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(indices),
        .{ .IndexBuffer = true, },
        .{}
    );
    errdefer indices_buffer.deinit();

    return Self {
        .vertices_buffer = vertices_buffer,
        .indices_buffer = indices_buffer,
        .outer_ring_indices_count = outer_ring_indices_count,
        .full_ring_indices_count = quad_indices_count + skirt_segment_vertices_count,
    };
}