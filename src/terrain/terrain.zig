const Self = @This();
const TerrainSystem = @import("terrain_system.zig");

const std = @import("std");
const eng = @import("engine");
const KeyCode = eng.input.KeyCode;
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;
const path = eng.path;
const Transform = eng.Transform;

const HeightFieldSize = 32;

pub const Descriptor = struct {
    enable_physics: bool = true,
    terrain_grid_scale: f32 = 1.0,
    terrain_height_scale: f32 = 1.0,
};

alloc: std.mem.Allocator,

heightmap: []f32,

terrain_grid_scale: f32 = 1.0,
height_scale: f32 = 1.0,

modify_radius: f32 = 1.0,
dbg_modify_center: [2]f32 = [_]f32{ 0.0, 0.0 },
dbg_modify_cells: [2][2]f32 = [_][2]f32{ [2]f32{ 0.0, 0.0 }, [2]f32{ 0.0, 0.0 } },

heightmap_texture: gf.Texture2D,
heightmap_texture_view: gf.TextureView2D,

physics_body_id: ?ph.zphy.BodyId = null,

pub fn deinit(self: *Self) void {
    self.heightmap_texture.deinit();
    self.heightmap_texture_view.deinit();
    self.remove_physics_body();
    self.alloc.free(self.heightmap);
}

pub fn init(alloc: std.mem.Allocator, desc: Descriptor, transform: Transform, gfx: *gf.GfxState) !Self {
    const heightmap_data = try alloc.alloc(f32, HeightFieldSize * HeightFieldSize);
    errdefer alloc.free(heightmap_data);

    for (0..HeightFieldSize) |y| {
        for (0..HeightFieldSize) |x| {
            heightmap_data[y * HeightFieldSize + x] = @mod(@as(f32, @floatFromInt(x)), 2.0) + @mod(@as(f32, @floatFromInt(y)), 2.0);
            heightmap_data[y * HeightFieldSize + x] /= 2.0;
            // const u: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(HeightFieldSize - 1));
            // const v: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(HeightFieldSize - 1));
            // heightmap_data[y * HeightFieldSize + x] = std.math.sin(u * std.math.pi * 2.0) * std.math.sin(v * std.math.pi * 2.0);
        }
    }

    // blk: {
    //     std.fs.cwd().writeFile(.{
    //         .sub_path = "heightmap.f32",
    //         .data = std.mem.sliceAsBytes(heightmap_data),
    //     }) catch |err| {
    //         std.log.err("unable to write heightmap.r32: {}", .{err});
    //         break :blk;
    //     };
    // }

    const heightmap_texture = try gf.Texture2D.init(
        .{
            .height = HeightFieldSize,
            .width = HeightFieldSize,
            .format = .R32_Float,
        },
        .{ .ShaderResource = true, },
        .{ .CpuWrite = true, },
        std.mem.sliceAsBytes(heightmap_data),
        gfx
    );
    errdefer heightmap_texture.deinit();

    const heightmap_texture_view = try gf.TextureView2D.init_from_texture2d(&heightmap_texture, gfx);
    errdefer heightmap_texture_view.deinit();

    var self = Self {
        .alloc = alloc,
        .terrain_grid_scale = desc.terrain_grid_scale,
        .height_scale = desc.terrain_height_scale,
        .heightmap_texture = heightmap_texture,
        .heightmap_texture_view = heightmap_texture_view,
        .heightmap = heightmap_data,
        .physics_body_id = null,
    };
    if (desc.enable_physics) {
        try self.generate_heightmap_physics(transform);
    }

    return self;
}

pub fn descriptor(self: *const Self, alloc: std.mem.Allocator) !Descriptor {
    _ = alloc;
    return Descriptor {
        .enable_physics = (self.physics_body_id != null),
        .terrain_grid_scale = self.terrain_grid_scale,
        .terrain_height_scale = self.height_scale,
    };
}

/// Removes the physics body from the terrain if it exists
fn remove_physics_body(self: *Self) void {
    if (self.physics_body_id) |*b| {
        const body_interface = eng.engine().physics.zphy.getBodyInterfaceMut();
        body_interface.removeAndDestroyBody(b.*);
        self.physics_body_id = null;
    }
}

/// Regenerates the heightmap physics body using the internal heightmap data
fn generate_heightmap_physics(self: *Self, transform: Transform) !void {
    const body_interface = eng.engine().physics.zphy.getBodyInterfaceMut();

    // create the new physics body
    const shape_settings = try ph.zphy.HeightFieldShapeSettings.create(self.heightmap.ptr, HeightFieldSize);
    defer shape_settings.release();

    const scaled_shape_settings = try ph.zphy.DecoratedShapeSettings.createScaled(
        shape_settings.asShapeSettings(), 
        [3]f32{ self.terrain_grid_scale, self.height_scale, self.terrain_grid_scale });
    defer scaled_shape_settings.release();

    const shape = try scaled_shape_settings.createShape();
    defer shape.release();

    const new_body = try body_interface.createAndAddBody(.{
        .shape = shape,
        .position = transform.position,
        .motion_type = .static,
    }, .activate);
    errdefer body_interface.removeAndDestroyBody(new_body);

    // Remove body if it exists
    self.remove_physics_body();
    
    // apply new physics body
    self.physics_body_id = new_body;
}

pub fn editor_ui(self: *Self, entity: *const eng.entity.EntitySuperStruct, key: anytype) void {
    const imui = &eng.engine().imui;

    const container = imui.push_layout(.Y, key ++ .{@src()});
    if (imui.get_widget(container)) |w| {
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        w.children_gap = 4;
    }
    defer imui.pop_layout();

    var physics_checkbox = (self.physics_body_id != null);
    const enable_physics_checkbox = imui.checkbox(&physics_checkbox, "physics", key ++ .{@src()});
    if (enable_physics_checkbox.clicked) {
        if (physics_checkbox) {
            self.generate_heightmap_physics(entity.transform) catch |err| {
                std.log.err("Failed to generate heightmap physics: {}", .{err});
            };
            std.log.info("Created physics body", .{});
        } else {
            self.remove_physics_body();
            std.log.info("Removed physics body", .{});
        }
    }

    {
        const ll = imui.push_layout(.X, key ++ .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        _ = imui.label("grid scale: ");
        _ = imui.number_slider(&self.terrain_grid_scale, .{}, key ++ .{@src()});
    }
    {
        const ll = imui.push_layout(.X, key ++ .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        _ = imui.label("height scale: ");
        _ = imui.number_slider(&self.height_scale, .{}, key ++ .{@src()});
    }
    {
        const ll = imui.push_layout(.X, key ++ .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        _ = imui.label("modify radius: ");
        _ = imui.number_slider(&self.modify_radius, .{}, key ++ .{@src()});
    }
}

pub fn edit_terrain(self: *Self, terrain_system: *TerrainSystem) !bool {
    var modify_terrain: f32 = 0.0;
    if (eng.engine().input.get_key(KeyCode.MouseLeft)) {
        if (eng.engine().input.get_key(KeyCode.Shift)) {
            modify_terrain -= 1.0;
        } else {
            modify_terrain += 1.0;
        }
    }

    self.dbg_modify_cells[0] = .{ 0.0, 0.0 };
    self.dbg_modify_cells[1] = .{ 0.0, 0.0 };
    self.dbg_modify_center = .{ 0.0, 0.0 };

    if (modify_terrain != 0.0) {
        const mouse_pos = eng.engine().input.cursor_position;
        if (mouse_pos[0] < 0 or mouse_pos[1] < 0) {
            return false;
        }

        const terrain_uv = terrain_system.selection_textures
            .get_value_at_position(@intCast(mouse_pos[0]), @intCast(mouse_pos[1]), &eng.engine().gfx) catch {
                return false;
            };
        if (terrain_uv[0] < 0.0 or terrain_uv[1] < 0.0) {
            return false;
        }
        const terrain_uv_v = zm.loadArr2(terrain_uv);
        const heightfield_size_f32_m1 = @as(f32, @floatFromInt(HeightFieldSize - 1));
        const heightmap_modify_center = terrain_uv_v * zm.f32x4s(heightfield_size_f32_m1);

        const max_modify_distance_cells: f32 = self.modify_radius / self.terrain_grid_scale;
        const min_x: i32 = @intFromFloat(@max(@floor(heightmap_modify_center[0] - max_modify_distance_cells), 0.0));
        const max_x: i32 = @intFromFloat(@min(@ceil(heightmap_modify_center[0] + max_modify_distance_cells), @as(f32, @floatFromInt(HeightFieldSize - 1))));
        const min_y: i32 = @intFromFloat(@max(@floor(heightmap_modify_center[1] - max_modify_distance_cells), 0.0));
        const max_y: i32 = @intFromFloat(@min(@ceil(heightmap_modify_center[1] + max_modify_distance_cells), @as(f32, @floatFromInt(HeightFieldSize - 1))));

        self.dbg_modify_center = terrain_uv;
        self.dbg_modify_cells[0][0] = @as(f32, @floatFromInt(min_x)) / @as(f32, @floatFromInt(HeightFieldSize));
        self.dbg_modify_cells[0][1] = @as(f32, @floatFromInt(max_x)) / @as(f32, @floatFromInt(HeightFieldSize));
        self.dbg_modify_cells[1][0] = @as(f32, @floatFromInt(min_y)) / @as(f32, @floatFromInt(HeightFieldSize));
        self.dbg_modify_cells[1][1] = @as(f32, @floatFromInt(max_y)) / @as(f32, @floatFromInt(HeightFieldSize));

        for (@intCast(min_x)..@intCast(max_x)) |x| {
            for (@intCast(min_y)..@intCast(max_y)) |y| {
                const idx: usize = x + y * HeightFieldSize;
                const cell = zm.f32x4(@floatFromInt(x), @floatFromInt(y), 0.0, 0.0);
                const distance_to_cell = zm.length2(cell - heightmap_modify_center)[0];
                const modify_strength = @max(0.0, (self.modify_radius - distance_to_cell) / @max(self.modify_radius * self.terrain_grid_scale, 0.01));
                self.heightmap[idx] += modify_terrain * eng.engine().time.delta_time_f32() * modify_strength;
            }
        }

        if (self.heightmap_texture.map_write_discard(f32, &eng.engine().gfx)) |mapped_texture| {
            defer mapped_texture.unmap();
            // TODO: this is incorrect, d3d11 row pitch is 128 but row length is 64. (when 16 HeightFieldSize)
            // probably need to do data() array access inside platform code
            @memcpy(mapped_texture.data(), self.heightmap);
        } else |err| {
            std.log.err("Failed to map terrain texture: {}", .{err});
        }
    }

    return modify_terrain != 0.0;
}
