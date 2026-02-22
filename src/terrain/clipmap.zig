const std = @import("std");
const eng = @import("engine");
const gf = eng.gfx;
const zm = eng.zmath;

const Self = @This();

const GeometryTranslationRotation = extern struct {
    translation: [2]f32 = .{0.0, 0.0},
    rotations_90: u8 = 0,
};

pub const ClipmapPushConstant = extern struct {
    translation: [2]f32,
    data: packed struct (u32) {
        rotations_90: u8,
        level: u8,
        _pad: u16 = 0,
    },
};

// TODO improve skirt transition. Reduce quad section size by 1 and improve rounding in shader so that clipmap levels dont overlap.
// TODO split clipmaps into segments https://developer.nvidia.com/gpugems/gpugems2/part-i-geometric-complexity/chapter-2-terrain-rendering-using-gpu-based-geometry
alloc: std.mem.Allocator,

vertices_buffer: gf.Buffer.Ref,
indices_buffer: gf.Buffer.Ref,

mxm_indices_base: u32,
mxm_indices_cout: u32,
mxm_model_locations: []GeometryTranslationRotation,

fixup_indices: struct {
    base: u32,
    count: u32,
    reversed_base: u32,
    reversed_count: u32,
},

fixup_translations: []GeometryTranslationRotation,

middle_translations: []GeometryTranslationRotation,

interior_trim_indices: struct {
    base: u32,
    count: u32,
    reversed_base: u32,
    reversed_count: u32,
},

degenerate_triangles_indices_base: u32,
degenerate_triangles_indices_count: u32,

interior_trim_locations: struct {
    pz_px: GeometryTranslationRotation,
    pz_nx: GeometryTranslationRotation,
    nz_px: GeometryTranslationRotation,
    nz_nx: GeometryTranslationRotation,
},

pub fn deinit(self: *const Self) void {
    self.vertices_buffer.deinit();
    self.indices_buffer.deinit();
    self.alloc.free(self.mxm_model_locations);
    self.alloc.free(self.fixup_translations);
    self.alloc.free(self.middle_translations);
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
                const quad_verts = quad_verts_a[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast((i * m) + j);
                try indices_list.append(alloc, base_index + (quad_verts[0] * m) + quad_verts[1]);
            }
        }
    }
    
    const mxm_indices_base = 0;
    const mxm_indices_count = (m-1) * (m-1) * 6;

    const fix_up_indices_base = 0;
    const fix_up_indices_count = (m-1) * fix_up_edge_length * 6;

    const fix_up_r_indices_base: u32 = @intCast(indices_list.items.len);

    for (0..m) |i| {
        for (0..m) |j| {
            const vert = zm.f32x4(@floatFromInt(i), 0.0, @floatFromInt(j), 0.0);
            try vertices_list.append(alloc, zm.vecToArr3(vert));
        }
    }

    for (0..(m-1)) |i| {
        for (0..(m-1)) |j| {
            for (0..6) |vti| {
                const quad_verts = quad_verts_b[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast((i * m) + j);
                try indices_list.append(alloc, base_index + (quad_verts[0] * m) + quad_verts[1]);
            }
        }
    }

    const fix_up_r_indices_count = (m-1) * fix_up_edge_length * 6;

    // interior trim
    const interior_trim_indices_base, const interior_trim_indices_count = blk: {
        // interior trim (top)
        const trim_base_index: u32 = @intCast(indices_list.items.len);

        var interior_trim_base_vertex = vertices_list.items.len;
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 0.0, 0.0)));
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 1.0, 0.0)));

        for (0..(((m-1) * 2) + fix_up_edge_length + 1)) |i| {
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
        
        for (0..(((m-1) * 2) + fix_up_edge_length)) |i| {
            try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, @floatFromInt(i + 2), 0.0)));
            try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(1.0, 0.0, @floatFromInt(i + 2), 0.0)));
            for (0..6) |vti| {
                const quad_verts = quad_verts_a[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast(interior_trim_base_vertex + (2 * i));
                try indices_list.append(alloc, base_index + quad_verts[0] + (2 * quad_verts[1]));
            }
        }

        const indices_count = @as(u32, @intCast(indices_list.items.len)) - trim_base_index;

        break :blk .{ trim_base_index, indices_count };
    };

    // interior trim reversed
    const interior_trim_r_indices_base, const interior_trim_r_indices_count = blk: {
        // interior trim (top)
        const trim_base_index: u32 = @intCast(indices_list.items.len);

        var interior_trim_base_vertex = vertices_list.items.len;
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 0.0, 0.0)));
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 1.0, 0.0)));

        for (0..(((m-1) * 2) + fix_up_edge_length + 1)) |i| {
            try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(@floatFromInt(i), 0.0, 0.0, 0.0)));
            try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(@floatFromInt(i), 0.0, 1.0, 0.0)));
            for (0..6) |vti| {
                const quad_verts = quad_verts_b[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast(interior_trim_base_vertex + (2 * i));
                try indices_list.append(alloc, base_index + quad_verts[1] + (2 * quad_verts[0]));
            }
        }
        
        // interior trim (right)
        interior_trim_base_vertex = vertices_list.items.len;
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, 1.0, 0.0)));
        try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(1.0, 0.0, 1.0, 0.0)));
        
        for (0..(((m-1) * 2) + fix_up_edge_length)) |i| {
            try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(0.0, 0.0, @floatFromInt(i + 2), 0.0)));
            try vertices_list.append(alloc, zm.vecToArr3(zm.f32x4(1.0, 0.0, @floatFromInt(i + 2), 0.0)));
            for (0..6) |vti| {
                const quad_verts = quad_verts_b[vti];// (if (((i % 2) == 0) != ((j % 2) == 0)) quad_verts_a else quad_verts_b)[vti];
                const base_index: u32 = @intCast(interior_trim_base_vertex + (2 * i));
                try indices_list.append(alloc, base_index + quad_verts[0] + (2 * quad_verts[1]));
            }
        }

        const indices_count = @as(u32, @intCast(indices_list.items.len)) - trim_base_index;

        break :blk .{ trim_base_index, indices_count };
    };

    const degenerate_triangles_start_index: u32 = @intCast(indices_list.items.len);

    // degenerate triangles (top)
    const degenerate_triangles_per_side = @divExact(side_length - 1, 2);
    for (0..degenerate_triangles_per_side) |t| {
        const t_f32: f32 = @floatFromInt(t);

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ -side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 0.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ -side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 1.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ -side_length_quads_f32 / 2.0, 0.0, (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 2.0 });
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
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 1.0, 0.0, side_length_quads_f32 / 2.0 });

        try indices_list.append(alloc, @intCast(vertices_list.items.len));
        try vertices_list.append(alloc, .{ (t_f32 * 2.0) + (-side_length_quads_f32 / 2.0) + 2.0, 0.0, side_length_quads_f32 / 2.0 });
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

    const mxm_quad_model_matrices = try alloc.alloc(GeometryTranslationRotation, 12);
    errdefer alloc.free(mxm_quad_model_matrices);
    var mxm_quad_model_matrices_list = std.ArrayList(GeometryTranslationRotation).initBuffer(mxm_quad_model_matrices);

    // 1, 2, 3, 4
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{-side_length_quads_f32 / 2.0, -side_length_quads_f32 / 2.0}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(-side_length_quads_f32 / 2.0) + m_f32_m1, -side_length_quads_f32 / 2.0}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(side_length_quads_f32 / 2.0) - m_f32_m1, -side_length_quads_f32 / 2.0}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0), -side_length_quads_f32 / 2.0}});

    // 5, 6
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{-side_length_quads_f32 / 2.0, (-side_length_quads_f32 / 2.0) + m_f32_m1}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(side_length_quads_f32 / 2.0) - m_f32_m1, (-side_length_quads_f32 / 2.0) + m_f32_m1}});

    // 7, 8
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{-side_length_quads_f32 / 2.0, (side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0)}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(side_length_quads_f32 / 2.0) - m_f32_m1, (side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0)}});

    // 9, 10, 11, 12
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{-side_length_quads_f32 / 2.0, (side_length_quads_f32 / 2.0) - m_f32_m1}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(-side_length_quads_f32 / 2.0) + m_f32_m1, (side_length_quads_f32 / 2.0) - m_f32_m1}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(side_length_quads_f32 / 2.0) - m_f32_m1, (side_length_quads_f32 / 2.0) - m_f32_m1}});
    try mxm_quad_model_matrices_list.appendBounded(.{ .translation = .{(side_length_quads_f32 / 2.0) - (m_f32_m1 * 2.0), (side_length_quads_f32 / 2.0) - m_f32_m1}});

    // fixup locations
    const fixup_model_matrices = try alloc.alloc(GeometryTranslationRotation, 4);
    errdefer alloc.free(fixup_model_matrices);
    var fixup_model_matrices_list = std.ArrayList(GeometryTranslationRotation).initBuffer(fixup_model_matrices);

    const fixup_translation = [2]f32 {-1.0, -side_length_quads_f32 / 2.0};

    // first two are normal, last two are reversed
    try fixup_model_matrices_list.appendBounded(.{ .translation = fixup_translation, .rotations_90 = 0, });
    try fixup_model_matrices_list.appendBounded(.{ .translation = fixup_translation, .rotations_90 = 2, });
    try fixup_model_matrices_list.appendBounded(.{ .translation = fixup_translation, .rotations_90 = 1, });
    try fixup_model_matrices_list.appendBounded(.{ .translation = fixup_translation, .rotations_90 = 3, });

    // middle locations
    const middle_model_matrices = try alloc.alloc(GeometryTranslationRotation, 4);
    errdefer alloc.free(middle_model_matrices);
    var middle_model_matrices_list = std.ArrayList(GeometryTranslationRotation).initBuffer(middle_model_matrices);

    try middle_model_matrices_list.appendBounded(.{ .translation = .{ -m_f32_m1, -m_f32_m1} });
    try middle_model_matrices_list.appendBounded(.{ .translation = .{ 0.0, -m_f32_m1} });
    try middle_model_matrices_list.appendBounded(.{ .translation = .{ -m_f32_m1, 0.0} });
    try middle_model_matrices_list.appendBounded(.{ .translation = .{ 0.0, 0.0} });

    // trim locations
    const trim_location_nz_nx = GeometryTranslationRotation { .translation = .{-@as(f32, @floatFromInt(m)), -@as(f32, @floatFromInt(m))}, .rotations_90 = 0, };
    const trim_location_pz_nx = GeometryTranslationRotation { .translation = .{-@as(f32, @floatFromInt(m)), -@as(f32, @floatFromInt(m))}, .rotations_90 = 1, };
    const trim_location_pz_px = GeometryTranslationRotation { .translation = .{-@as(f32, @floatFromInt(m)), -@as(f32, @floatFromInt(m))}, .rotations_90 = 2, };
    const trim_location_nz_px = GeometryTranslationRotation { .translation = .{-@as(f32, @floatFromInt(m)), -@as(f32, @floatFromInt(m))}, .rotations_90 = 3, };

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

        .mxm_indices_base = mxm_indices_base,
        .mxm_indices_cout = mxm_indices_count,
        .mxm_model_locations = mxm_quad_model_matrices,

        .fixup_indices = .{
            .base = fix_up_indices_base,
            .count = fix_up_indices_count,
            .reversed_base = fix_up_r_indices_base,
            .reversed_count = fix_up_r_indices_count,
        },
        .fixup_translations = fixup_model_matrices,

        .middle_translations = middle_model_matrices,

        .interior_trim_indices = .{
            .base = interior_trim_indices_base,
            .count = interior_trim_indices_count,
            .reversed_base = interior_trim_r_indices_base,
            .reversed_count = interior_trim_r_indices_count,
        },

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

pub fn render_clipmap_geometry(
    self: *const Self,
    cmd: *gf.CommandBuffer,
    num_levels: usize,
    push_constant_shader_stages: gf.ShaderStageFlags,
    clipmap_push_constant_offset: u32,
    camera_position: zm.F32x4,
) void {
    cmd.cmd_bind_vertex_buffers(.{
        .buffers = &.{
            .{ .buffer = self.vertices_buffer, },
        },
    });
    cmd.cmd_bind_index_buffer(.{
        .buffer = self.indices_buffer,
        .index_format = .U32,
    });

    var push_constant_data = ClipmapPushConstant {
        .translation = .{0.0, 0.0},
        .data = .{
            .rotations_90 = 0,
            .level = 0,
        },
    };

    for (self.middle_translations) |loc| {
        push_constant_data.translation = loc.translation;
        push_constant_data.data.rotations_90 = loc.rotations_90;

        cmd.cmd_push_constants(.{
            .shader_stages = push_constant_shader_stages,
            .offset = clipmap_push_constant_offset,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .index_count = self.mxm_indices_cout,
        });
    }

    // draw trim around center level quads
    {
        // draw trim (pz px)
        push_constant_data.translation = self.interior_trim_locations.pz_px.translation;
        push_constant_data.data.rotations_90 = self.interior_trim_locations.pz_px.rotations_90;
        
        cmd.cmd_push_constants(.{
            .shader_stages = push_constant_shader_stages,
            .offset = clipmap_push_constant_offset,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .first_index = self.interior_trim_indices.base,
            .index_count = self.interior_trim_indices.count,
        });

        // draw trim (nz nx) (skipping first and last quad since that is drawn in pz px)
        push_constant_data.translation = self.interior_trim_locations.nz_nx.translation;
        push_constant_data.data.rotations_90 = self.interior_trim_locations.nz_nx.rotations_90;
        
        cmd.cmd_push_constants(.{
            .shader_stages = push_constant_shader_stages,
            .offset = clipmap_push_constant_offset,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .first_index = self.interior_trim_indices.base,
            .index_count = self.interior_trim_indices.count,
        });
    }

    for (0..num_levels) |level| {
        const level_u8: u8 = @intCast(level);

        for (self.mxm_model_locations) |loc| {
            push_constant_data.translation = loc.translation;
            push_constant_data.data.rotations_90 = loc.rotations_90;
            push_constant_data.data.level = level_u8;

            cmd.cmd_push_constants(.{
                .shader_stages = push_constant_shader_stages,
                .offset = clipmap_push_constant_offset,
                .data = std.mem.asBytes(&push_constant_data),
            });

            cmd.cmd_draw_indexed(.{
                .index_count = self.mxm_indices_cout,
            });
        }

        for (self.fixup_translations, 0..) |loc, idx| {
            push_constant_data.translation = loc.translation;
            push_constant_data.data.rotations_90 = loc.rotations_90;
            push_constant_data.data.level = level_u8;

            cmd.cmd_push_constants(.{
                .shader_stages = push_constant_shader_stages,
                .offset = clipmap_push_constant_offset,
                .data = std.mem.asBytes(&push_constant_data),
            });

            cmd.cmd_draw_indexed(.{
                .first_index = if (idx < 2) self.fixup_indices.base else self.fixup_indices.reversed_base,
                .index_count = if (idx < 2) self.fixup_indices.count else self.fixup_indices.reversed_count,
            });
        }

        // draw degenerate triangles
        push_constant_data.translation = .{ 0.0, 0.0 };
        push_constant_data.data.rotations_90 = 0;
        push_constant_data.data.level = level_u8;

        cmd.cmd_push_constants(.{
            .shader_stages = push_constant_shader_stages,
            .offset = clipmap_push_constant_offset,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .first_index = self.degenerate_triangles_indices_base,
            .index_count = self.degenerate_triangles_indices_count,
        });

        // draw inner trim
        const quant_level_scale_l0 = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(level)) + 0.0);
        const quantised_camera_position_l0 = (zm.floor(camera_position / zm.f32x4s(quant_level_scale_l0)) + zm.f32x4s(0.5)) * zm.f32x4s(quant_level_scale_l0);
        
        const quant_level_scale_l1 = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(level)) + 1.0);
        const quantised_camera_position_l1 = (zm.floor(camera_position / zm.f32x4s(quant_level_scale_l1)) + zm.f32x4s(0.5)) * zm.f32x4s(quant_level_scale_l1);

        const quantised_camera_larger = quantised_camera_position_l0 > quantised_camera_position_l1;

        const trim_model_matrix, const trim_reversed = 
            if (quantised_camera_larger[0] and quantised_camera_larger[2]) .{ self.interior_trim_locations.nz_nx, false }
            else if (quantised_camera_larger[0] and !quantised_camera_larger[2]) .{ self.interior_trim_locations.nz_px, true }
            else if (!quantised_camera_larger[0] and quantised_camera_larger[2]) .{ self.interior_trim_locations.pz_nx, true }
            else .{ self.interior_trim_locations.pz_px, false };
            
        push_constant_data.translation = trim_model_matrix.translation;
        push_constant_data.data.rotations_90 = trim_model_matrix.rotations_90;
        push_constant_data.data.level = level_u8;

        cmd.cmd_push_constants(.{
            .shader_stages = push_constant_shader_stages,
            .offset = clipmap_push_constant_offset,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .first_index = if (!trim_reversed) self.interior_trim_indices.base else self.interior_trim_indices.reversed_base,
            .index_count = if (!trim_reversed) self.interior_trim_indices.count else self.interior_trim_indices.reversed_count,
        });
    }
}