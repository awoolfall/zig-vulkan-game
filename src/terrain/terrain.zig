const Self = @This();
const TerrainSystem = @import("terrain_system.zig");

const std = @import("std");
const eng = @import("engine");
const KeyCode = eng.input.KeyCode;
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;
const as = eng.assets;
const path = eng.path;
const Transform = eng.Transform;

const HeightFieldSize = 32;

pub const Descriptor = struct {
    heightmap_asset_id: ?as.Texture2DAssetId = null,
    enable_physics: bool = true,
    terrain_grid_scale: f32 = 1.0,
    terrain_height_scale: f32 = 1.0,
};

alloc: std.mem.Allocator,

heightmap_asset_id: ?as.Texture2DAssetId,
heightmap: []f32,

terrain_grid_scale: f32 = 1.0,
height_scale: f32 = 1.0,

heightmap_texture: gf.Image.Ref,
heightmap_texture_view: gf.ImageView.Ref,

physics_body_id: ?ph.zphy.BodyId = null,

modify_radius: f32 = 1.0,
dbg_modify_center: [2]f32 = [_]f32{ 0.0, 0.0 },
dbg_modify_cells: [2][2]f32 = [_][2]f32{ [2]f32{ 0.0, 0.0 }, [2]f32{ 0.0, 0.0 } },
modify_mode: ModifyMode = .GradiantLift,

const ModifyMode = enum {
    GradiantLift,
    Flatten,
};

pub fn deinit(self: *Self) void {
    self.heightmap_texture.deinit();
    self.heightmap_texture_view.deinit();
    self.remove_physics_body();
    self.alloc.free(self.heightmap);
}

pub fn init(alloc: std.mem.Allocator, desc: Descriptor, transform: Transform) !Self {
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

    const heightmap_texture = try gf.Image.init(
        .{
            .height = HeightFieldSize,
            .width = HeightFieldSize,
            .format = .R32_Float,

            .usage_flags = .{ .ShaderResource = true, },
            .access_flags = .{ .CpuWrite = true, },
            .dst_layout = .ShaderReadOnlyOptimal,
        },
        std.mem.sliceAsBytes(heightmap_data),
    );
    errdefer heightmap_texture.deinit();

    const heightmap_texture_view = try gf.ImageView.init(.{ .image = heightmap_texture, });
    errdefer heightmap_texture_view.deinit();

    var self = Self {
        .alloc = alloc,
        .heightmap_asset_id = desc.heightmap_asset_id,
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
        .heightmap_asset_id = self.heightmap_asset_id,
        .enable_physics = (self.physics_body_id != null),
        .terrain_grid_scale = self.terrain_grid_scale,
        .terrain_height_scale = self.height_scale,
    };
}

/// Removes the physics body from the terrain if it exists
fn remove_physics_body(self: *Self) void {
    if (self.physics_body_id) |*b| {
        const body_interface = eng.get().physics.zphy.getBodyInterfaceMut();
        body_interface.removeAndDestroyBody(b.*);
        self.physics_body_id = null;
    }
}

/// Regenerates the heightmap physics body using the internal heightmap data
fn generate_heightmap_physics(self: *Self, transform: Transform) !void {
    const body_interface = eng.get().physics.zphy.getBodyInterfaceMut();

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
    const imui = &eng.get().imui;

    const container = imui.push_layout(.Y, key ++ .{@src()});
    if (imui.get_widget(container)) |w| {
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        w.children_gap = 4;
    }
    defer imui.pop_layout();

    {
        const ll = imui.push_layout(.X, key ++ .{@src()});
        if (imui.get_widget(ll)) |ll_widget| {
            ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
            ll_widget.children_gap = 4;
        }
        defer imui.pop_layout();

        _ = imui.label("texture: ");
        _ = imui.number_slider(&self.terrain_grid_scale, .{}, key ++ .{@src()});
    }

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
    if (eng.get().input.get_key(KeyCode.MouseLeft)) {
        if (eng.get().input.get_key(KeyCode.Shift)) {
            modify_terrain -= 1.0;
        } else {
            modify_terrain += 1.0;
        }
    }

    self.dbg_modify_cells[0] = .{ 0.0, 0.0 };
    self.dbg_modify_cells[1] = .{ 0.0, 0.0 };
    self.dbg_modify_center = .{ 0.0, 0.0 };

    if (modify_terrain != 0.0) {
        const mouse_pos = eng.get().input.cursor_position;
        if (mouse_pos[0] < 0 or mouse_pos[1] < 0) {
            return false;
        }

        const heightfield_size_f32 = @as(f32, @floatFromInt(HeightFieldSize));

        const terrain_uv = terrain_system.selection_textures
            .get_value_at_position(@intCast(mouse_pos[0]), @intCast(mouse_pos[1])) catch {
                return false;
            };
        if (terrain_uv[0] < 0.0 or terrain_uv[1] < 0.0) {
            return false;
        }
        const terrain_uv_v = zm.loadArr2(terrain_uv);
    
        const heightmap_modify_center = terrain_uv_v * zm.f32x4s(heightfield_size_f32);

        const max_modify_distance_cells: f32 = (self.modify_radius / self.terrain_grid_scale) * 1.5;
        const min_x: i32 = @intFromFloat(@max(@floor(heightmap_modify_center[0] - max_modify_distance_cells), 0.0));
        const max_x: i32 = @intFromFloat(@min(@ceil(heightmap_modify_center[0] + max_modify_distance_cells), heightfield_size_f32));
        const min_y: i32 = @intFromFloat(@max(@floor(heightmap_modify_center[1] - max_modify_distance_cells), 0.0));
        const max_y: i32 = @intFromFloat(@min(@ceil(heightmap_modify_center[1] + max_modify_distance_cells), heightfield_size_f32));

        self.dbg_modify_center = terrain_uv;
        self.dbg_modify_cells[0][0] = @as(f32, @floatFromInt(min_x)) / heightfield_size_f32;
        self.dbg_modify_cells[0][1] = @as(f32, @floatFromInt(max_x)) / heightfield_size_f32;
        self.dbg_modify_cells[1][0] = @as(f32, @floatFromInt(min_y)) / heightfield_size_f32;
        self.dbg_modify_cells[1][1] = @as(f32, @floatFromInt(max_y)) / heightfield_size_f32;

        switch (self.modify_mode) {
            .GradiantLift => {
                for (@intCast(min_x)..@intCast(max_x)) |x| {
                    for (@intCast(min_y)..@intCast(max_y)) |y| {
                        const idx: usize = x + y * HeightFieldSize;
                        const cell = zm.f32x4(@floatFromInt(x), @floatFromInt(y), 0.0, 0.0);
                        const distance_to_cell = zm.length2(cell - heightmap_modify_center)[0];
                        const modify_radius_cells = self.modify_radius / self.terrain_grid_scale;
                        const modify_strength = @max(0.0, (modify_radius_cells - distance_to_cell) / @max(modify_radius_cells, 0.01));
                        self.heightmap[idx] += modify_terrain * eng.get().time.delta_time_f32() * modify_strength;
                    }
                }
            },
            .Flatten => {
                const center_cell_idx: usize = 
                    @as(usize, @intFromFloat(@round(heightmap_modify_center[0]))) + 
                    @as(usize, @intFromFloat(@round(heightmap_modify_center[1]))) * HeightFieldSize;
                const center_cell_value = self.heightmap[center_cell_idx];
                for (@intCast(min_x)..@intCast(max_x)) |x| {
                    for (@intCast(min_y)..@intCast(max_y)) |y| {
                        const idx: usize = x + y * HeightFieldSize;
                        const cell = zm.f32x4(@floatFromInt(x), @floatFromInt(y), 0.0, 0.0);
                        const distance_to_cell = zm.length2(cell - heightmap_modify_center)[0];
                        if (distance_to_cell <= (self.modify_radius / self.terrain_grid_scale)) {
                            self.heightmap[idx] = center_cell_value;
                        }
                    }
                }
            },
        }

        const heightmap_image = try self.heightmap_texture.get();
        if (heightmap_image.map(.{ .write = true, })) |mapped_texture| {
            defer mapped_texture.unmap();
            // TODO: this is incorrect, d3d11 row pitch is 128 but row length is 64. (when 16 HeightFieldSize)
            // probably need to do data() array access inside platform code
            @memcpy(mapped_texture.data(f32), self.heightmap);
        } else |err| {
            std.log.err("Failed to map terrain texture: {}", .{err});
        }
    }

    return modify_terrain != 0.0;
}
