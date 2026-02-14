const std = @import("std");
const eng = @import("engine");
const gf = eng.gfx;
const zm = eng.zmath;

const Self = @This();

// TODO improve skirt transition. Reduce quad section size by 1 and improve rounding in shader so that clipmap levels dont overlap.
// TODO split clipmaps into segments https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry
alloc: std.mem.Allocator,

vertices_buffer: gf.Buffer.Ref,
indices_buffer: gf.Buffer.Ref,

mxm_indices_cout: u32,
mxm_model_matrices: []zm.Mat,

fixup_indices_count: u32,
fixup_model_matrices: []zm.Mat,

middle_model_matrices: []zm.Mat,

interior_trim_indices_base: u32,
interior_trim_indices_count: u32,

degenerate_triangles_indices_base: u32,
degenerate_triangles_indices_count: u32,

interior_trim_locations: struct {
    pz_px: zm.Mat,
    pz_nx: zm.Mat,
    nz_px: zm.Mat,
    nz_nx: zm.Mat,
},

pub fn deinit(self: *const Self) void {
    self.vertices_buffer.deinit();
    self.indices_buffer.deinit();
    self.alloc.free(self.mxm_model_matrices);
    self.alloc.free(self.fixup_model_matrices);
    self.alloc.free(self.middle_model_matrices);
}

pub fn init(alloc: std.mem.Allocator, side_length: u32) !Self {
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

    const m = @divExact(side_length + 1, 4);
    const fix_up_edge_length = (side_length - 1) - ((m - 1) * 4);

    const m_f32_m1: f32 = @floatFromInt(m - 1);
    const side_length_quads_f32: f32 = @floatFromInt(side_length - 1);

    var vertices_list = try std.ArrayList([3]f32).initCapacity(alloc, 32);
    defer vertices_list.deinit(alloc);

    var indices_list = try std.ArrayList(u32).initCapacity(alloc, 32);
    defer indices_list.deinit(alloc);

    for (0..m) |i| {
        for (0..m) |j| {
            const vert = zm.f32x4(@floatFromInt(i), 0.0, @floatFromInt(j), 0.0);
            try vertices_list.append(alloc, zm.vecToArr3(vert));
        }
    }

    for (0..(m-1)) |i| {
        for (0..(m-1)) |j| {
            for (0..6) |vti| {
                _ = quad_verts_b;
                const quad_verts = quad_verts_a[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast((i * m) + j);
                try indices_list.append(alloc, base_index + (quad_verts[0] * m) + quad_verts[1]);
            }
        }
    }
    
    const mxm_indices_count = (m-1) * (m-1) * 6;
    const fix_up_indices_count = (m-1) * fix_up_edge_length * 6;

    // interior trim (top)
    const interior_trim_base_index: u32 = @intCast(indices_list.items.len);

    var interior_trim_base_vertex = vertices_list.items.len;
    try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 0.0, 0.0)));
    try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 1.0, 0.0)));

    for (0..(((m-1) * 2) + fix_up_edge_length)) |i| {
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(@floatFromInt(i), 0.0, 0.0, 0.0)));
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(@floatFromInt(i), 0.0, 1.0, 0.0)));
        for (0..6) |vti| {
            const quad_verts = quad_verts_a[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
            const base_index: u32 = @intCast(interior_trim_base_vertex + (2 * i));
            try indices_list.append(alloc, base_index + quad_verts[1] + (2 * quad_verts[0]));
        }
    }
    
    // interior trim (right)
    interior_trim_base_vertex = vertices_list.items.len;
    try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 1.0, 0.0)));
    try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(1.0, 0.0, 1.0, 0.0)));
    
    for (1..(((m-1) * 2) + fix_up_edge_length)) |i| {
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, @floatFromInt(i), 0.0)));
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(1.0, 0.0, @floatFromInt(i), 0.0)));
        for (0..6) |vti| {
            const quad_verts = quad_verts_a[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
            const base_index: u32 = @intCast(interior_trim_base_vertex + (2 * i));
            try indices_list.append(alloc, base_index + quad_verts[0] + (2 * quad_verts[1]));
        }
    }

    const interior_trim_indices_count = @as(u32, @intCast(indices_list.items.len)) - interior_trim_base_index;

    const degenerate_triangles_start_index: u32 = @intCast(indices_list.items.len);

    // degenerate triangles (top)
    const degenerate_triangles_per_side = @divExact(side_length - 1, 2);
    for (0..degenerate_triangles_per_side) |t| {
        const t_f32: f32 = @floatFromInt(t);

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ -side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 0.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ -side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 2.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ -side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 1.0 });
    }
    // degenerate triangles (bottom)
    for (0..degenerate_triangles_per_side) |t| {
        const t_f32: f32 = @floatFromInt(t);

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 0.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 2.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 1.0 });
    }
    // degenerate triangles (left)
    for (0..degenerate_triangles_per_side) |t| {
        const t_f32: f32 = @floatFromInt(t);

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 0.0, 0.0, -side_length_quads_f32 / 2.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 2.0, 0.0, -side_length_quads_f32 / 2.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 1.0, 0.0, -side_length_quads_f32 / 2.0 });
    }
    // degenerate triangles (right)
    for (0..degenerate_triangles_per_side) |t| {
        const t_f32: f32 = @floatFromInt(t);

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 0.0, 0.0, side_length_quads_f32 / 2.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 2.0, 0.0, side_length_quads_f32 / 2.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 1.0, 0.0, side_length_quads_f32 / 2.0 });
    }

    const degenerate_triangles_indices_count = @as(u32, @intCast(indices_list.items.len)) - degenerate_triangles_start_index;

    // see: https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry
    // mxm quad locations
    // |------------|
    // |1 2      3 4|
    // |5          6|
    // |            |
    // |7          8|
    // |9 10   11 12|
    // |------------|

    const mxm_quad_model_matrices = try alloc.alloc(zm.Mat, 12);
    errdefer alloc.free(mxm_quad_model_matrices);
    var mxm_quad_model_matrices_list = std.ArrayList(zm.Mat).initBuffer(mxm_quad_model_matrices);

    // 1, 2, 3, 4
    try mxm_quad_model_matrices_list.appendBounded(zm.translation(-side_length_quads_f32 / 2.0, 0.0, -side_length_quads_f32 / 2.0));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((-side_length_quads_f32 / 2.0) + m_f32_m1, 0.0, -side_length_quads_f32 / 2.0));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((side_length_quads_f32 / 2.0) - m_f32_m1, 0.0, -side_length_quads_f32 / 2.0));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0), 0.0, -side_length_quads_f32 / 2.0));

    // 5, 6
    try mxm_quad_model_matrices_list.appendBounded(zm.translation(-side_length_quads_f32 / 2.0, 0.0, (-side_length_quads_f32 / 2.0) + m_f32_m1));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((side_length_quads_f32 / 2.0) - m_f32_m1, 0.0, (-side_length_quads_f32 / 2.0) + m_f32_m1));

    // 7, 8
    try mxm_quad_model_matrices_list.appendBounded(zm.translation(-side_length_quads_f32 / 2.0, 0.0, (side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0)));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((side_length_quads_f32 / 2.0) - m_f32_m1, 0.0, (side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0)));

    // 9, 10, 11, 12
    try mxm_quad_model_matrices_list.appendBounded(zm.translation(-side_length_quads_f32 / 2.0, 0.0, (side_length_quads_f32 / 2.0) - m_f32_m1));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((-side_length_quads_f32 / 2.0) + m_f32_m1, 0.0, (side_length_quads_f32 / 2.0) - m_f32_m1));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((side_length_quads_f32 / 2.0) - m_f32_m1, 0.0, (side_length_quads_f32 / 2.0) - m_f32_m1));
    try mxm_quad_model_matrices_list.appendBounded(zm.translation((side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0), 0.0, (side_length_quads_f32 / 2.0) - m_f32_m1));

    // fixup locations
    const fixup_model_matrices = try alloc.alloc(zm.Mat, 4);
    errdefer alloc.free(fixup_model_matrices);
    var fixup_model_matrices_list = std.ArrayList(zm.Mat).initBuffer(fixup_model_matrices);

    const fixup_translation = zm.translation(-1.0, 0.0, -side_length_quads_f32 / 2.0);

    try fixup_model_matrices_list.appendBounded(zm.mul(fixup_translation, zm.rotationY(0.0 * std.math.pi / 2.0)));
    try fixup_model_matrices_list.appendBounded(zm.mul(fixup_translation, zm.rotationY(1.0 * std.math.pi / 2.0)));
    try fixup_model_matrices_list.appendBounded(zm.mul(fixup_translation, zm.rotationY(2.0 * std.math.pi / 2.0)));
    try fixup_model_matrices_list.appendBounded(zm.mul(fixup_translation, zm.rotationY(3.0 * std.math.pi / 2.0)));

    // middle locations
    const middle_model_matrices = try alloc.alloc(zm.Mat, 4);
    errdefer alloc.free(middle_model_matrices);
    var middle_model_matrices_list = std.ArrayList(zm.Mat).initBuffer(middle_model_matrices);

    try middle_model_matrices_list.appendBounded(zm.translation(-m_f32_m1, 0.0, -m_f32_m1));
    try middle_model_matrices_list.appendBounded(zm.translation(0.0, 0.0, -m_f32_m1));
    try middle_model_matrices_list.appendBounded(zm.translation(-m_f32_m1, 0.0, 0.0));
    try middle_model_matrices_list.appendBounded(zm.translation(0.0, 0.0, 0.0));

    // trim locations
    const trim_location_nz_nx = zm.translation(-@as(f32, @floatFromInt(m)), 0.0, -@as(f32, @floatFromInt(m)));
    const trim_location_pz_nx = zm.mul(trim_location_nz_nx, zm.rotationY(1.0 * std.math.pi / 2.0));
    const trim_location_pz_px = zm.mul(trim_location_nz_nx, zm.rotationY(2.0 * std.math.pi / 2.0));
    const trim_location_nz_px = zm.mul(trim_location_nz_nx, zm.rotationY(3.0 * std.math.pi / 2.0));

    const vertices_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(vertices_list.items),
        .{ .VertexBuffer = true, },
        .{}
    );
    errdefer vertices_buffer.deinit();

    const indices_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(indices_list.items),
        .{ .IndexBuffer = true, },
        .{}
    );
    errdefer indices_buffer.deinit();

    return Self {
        .alloc = alloc,
        
        .vertices_buffer = vertices_buffer,
        .indices_buffer = indices_buffer,

        .mxm_indices_cout = mxm_indices_count,
        .mxm_model_matrices = mxm_quad_model_matrices,

        .fixup_indices_count = fix_up_indices_count,
        .fixup_model_matrices = fixup_model_matrices,

        .middle_model_matrices = middle_model_matrices,

        .interior_trim_indices_base = interior_trim_base_index,
        .interior_trim_indices_count = interior_trim_indices_count,

        .interior_trim_locations = .{
            .nz_nx = trim_location_nz_nx,
            .pz_nx = trim_location_pz_nx,
            .nz_px = trim_location_nz_px,
            .pz_px = trim_location_pz_px,
        },

        .degenerate_triangles_indices_base = degenerate_triangles_start_index,
        .degenerate_triangles_indices_count = degenerate_triangles_indices_count,
    };
}