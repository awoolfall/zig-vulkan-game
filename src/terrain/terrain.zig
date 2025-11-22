const Self = @This();

const std = @import("std");
const eng = @import("engine");
const TerrainRenderer = @import("terrain_renderer.zig");
const KeyCode = eng.input.KeyCode;
const zm = eng.zmath;
const gf = eng.gfx;
const Imui = eng.ui;
const ph = eng.physics;
const as = eng.assets;
const path = eng.path;
const Transform = eng.Transform;

const HeightFieldSize = 32;

pub const Descriptor = struct {
    heightmap_asset_id: ?as.ImageAssetId = null,
    enable_physics: bool = true,

    map_length_m: f32 = 1000.0,
    map_length_scale: f32 = 1.0,

    map_minimum_height: f32 = 0.0,
    map_maximum_height: f32 = 100.0,
    map_height_scale: f32 = 1.0,
};

alloc: std.mem.Allocator,

heightmap_asset_id: ?as.ImageAssetId,
heightmap: []f32,

map_length_m: f32 = 1000.0,
map_length_scale: f32 = 1.0,

map_minimum_height: f32 = 0.0,
map_maximum_height: f32 = 100.0,
map_height_scale: f32 = 1.0,

heightmap_texture: gf.Image.Ref,
heightmap_texture_view: gf.ImageView.Ref,

normal_texture: gf.Image.Ref,
normal_texture_view: gf.ImageView.Ref,

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
    self.normal_texture.deinit();
    self.normal_texture_view.deinit();
    self.remove_physics_body();
    self.alloc.free(self.heightmap);
}

pub fn init(alloc: std.mem.Allocator, desc: Descriptor, transform: Transform) !Self {
    const hmt_id = try eng.get().asset_manager.find_asset_id(as.ImageAsset, "default|terrain-texture");
    const hmt = try eng.get().asset_manager.get_asset(as.ImageAsset, hmt_id);

    const hmt_image_asset = try eng.get().asset_manager.get_asset_entry(as.ImageAsset, hmt_id);

    var hmt_image = try hmt_image_asset.load_image_cpu(eng.get().general_allocator, 0);
    defer hmt_image.deinit();

    const heightmap_data = try alloc.alloc(f32, hmt_image.width * hmt_image.height);
    errdefer alloc.free(heightmap_data);

    // assert f32 image... TODO support other filetypes
    std.debug.assert(hmt_image.is_hdr and hmt_image.num_components == 1 and hmt_image.bytes_per_component == @sizeOf(f32));
    @memcpy(std.mem.sliceAsBytes(heightmap_data), hmt_image.data);

    const normal_data = try alloc.alloc(zm.F32x4, heightmap_data.len);
    defer alloc.free(normal_data);
    @memset(normal_data, zm.f32x4s(1.0));

    for (0..hmt_image.width) |w| {
        for (0..hmt_image.height) |h| {
            const idx: usize = w + (h * hmt_image.width);
            const idxm1: isize = @max((@as(isize, @intCast(w)) - 1) + @as(isize, @intCast(h * hmt_image.width)), 0);
            const idxp1: isize = @min((@as(isize, @intCast(w)) + 1) + @as(isize, @intCast(h * hmt_image.width)), @as(isize, @intCast(heightmap_data.len)) - 1);
            normal_data[idx][0] = 
                (heightmap_data[@intCast(idx)] - heightmap_data[@intCast(idxm1)] +
                heightmap_data[@intCast(idxp1)] - heightmap_data[@intCast(idx)]) / 2.0;
        }
    }
    for (0..hmt_image.height) |h| {
        for (0..hmt_image.width) |w| {
            const idx: usize = w + (h * hmt_image.width);
            const idxm1: isize = @max(@as(isize, @intCast(w)) + ((@as(isize, @intCast(h)) - 1) * hmt_image.width), 0);
            const idxp1: isize = @min(@as(isize, @intCast(w)) + ((@as(isize, @intCast(h)) + 1) * hmt_image.width), @as(isize, @intCast(heightmap_data.len)) - 1);
            normal_data[idx][1] = 
                (heightmap_data[@intCast(idx)] - heightmap_data[@intCast(idxm1)] +
                heightmap_data[@intCast(idxp1)] - heightmap_data[@intCast(idx)]) / 2.0;
        }
    }
    for (normal_data) |*n| {
        n.* = zm.normalize3(n.*);
    }

    const normal_data_u8 = try alloc.alloc([4]u8, normal_data.len);
    defer alloc.free(normal_data_u8);
    for (normal_data_u8, 0..) |*n, idx| {
        n.* = [4]u8{
            @intFromFloat(std.math.clamp((normal_data[idx][0] * 255.0) + 128.0, 0.0, 255.0)),
            @intFromFloat(std.math.clamp((normal_data[idx][1] * 255.0) + 128.0, 0.0, 255.0)),
            @intFromFloat(std.math.clamp(normal_data[idx][2] * 255.0, 0.0, 255.0)),
            255,
        };
    }

    var normal_image = try (eng.image.Image {
        .alloc = eng.get().general_allocator,
        .width = hmt_image.width,
        .height = hmt_image.height,
        .bytes_per_component = @sizeOf(u8),
        .num_components = 4,
        .bytes_per_row = (4 * @sizeOf(u8)) * hmt_image.width,
        .is_hdr = false,
        .data = std.mem.sliceAsBytes(normal_data_u8),
    }).to_zstbi();
    defer normal_image.deinit();

    const heightmap_texture_view = try gf.ImageView.init(.{ .image = hmt.*, .view_type = .ImageView2DArray, });
    errdefer heightmap_texture_view.deinit();

    const normal_texture = try gf.Image.init(
        .{
            .width = hmt_image.width,
            .height = hmt_image.height,
            .dst_layout = .ShaderReadOnlyOptimal,
            .format = .Rgba8_Unorm,
            .usage_flags = .{ .ShaderResource = true, },
            .access_flags = .{},
        },
        std.mem.sliceAsBytes(normal_data_u8),
    );
    errdefer normal_texture.deinit();

    const normal_texture_view = try gf.ImageView.init(.{ .image = normal_texture, .view_type = .ImageView2DArray, });
    errdefer normal_texture_view.deinit();

    var self = Self {
        .alloc = alloc,

        .heightmap_asset_id = desc.heightmap_asset_id,

        .map_length_m = desc.map_length_m,
        .map_length_scale = desc.map_length_scale,

        .map_minimum_height = desc.map_minimum_height,
        .map_maximum_height = desc.map_maximum_height,
        .map_height_scale = desc.map_height_scale,

        .heightmap_texture = hmt.*,
        .heightmap_texture_view = heightmap_texture_view,

        .normal_texture = normal_texture,
        .normal_texture_view = normal_texture_view,

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

        .map_length_m = self.map_length_m,
        .map_length_scale = self.map_length_scale,

        .map_minimum_height = self.map_minimum_height,
        .map_maximum_height = self.map_maximum_height,
        .map_height_scale = self.map_height_scale,
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
    const heightmap_side_length: u32 = @intCast(std.math.sqrt(self.heightmap.len));
    const shape_settings = try ph.zphy.HeightFieldShapeSettings.create(self.heightmap.ptr, heightmap_side_length);
    defer shape_settings.asShapeSettings().release();

    const heightmap_side_length_f32: f32 = @floatFromInt(heightmap_side_length);
    const scaled_shape_settings = try ph.zphy.DecoratedShapeSettings.createScaled(
        shape_settings.asShapeSettings(), 
        [3]f32{ self.map_length_m / heightmap_side_length_f32, self.map_height_scale, self.map_length_m / heightmap_side_length_f32 });
    defer scaled_shape_settings.asShapeSettings().release();

    const shape = try scaled_shape_settings.asShapeSettings().createShape();
    defer shape.release();

    const new_body = try body_interface.createAndAddBody(.{
        .shape = shape,
        .position = transform.position + 
            zm.f32x4(self.map_length_m/heightmap_side_length_f32, 0.0, self.map_length_m/heightmap_side_length_f32, 0.0) / zm.f32x4s(2.0),
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
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, };
        w.children_gap = 4;
    }
    defer imui.pop_layout();

    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "texture: ");
        _ = Imui.widgets.number_slider.create(imui, &self.map_length_m, .{}, key ++ .{@src()});
    }

    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "enable physics: ");

        var physics_checkbox = (self.physics_body_id != null);
        const enable_physics_checkbox = Imui.widgets.checkbox.create(imui, &physics_checkbox, "", key ++ .{@src()});

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
    }

    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "map length (m): ");
        _ = Imui.widgets.number_slider.create(imui, &self.map_length_m, .{}, key ++ .{@src()});
    }
    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "map length scale: ");
        _ = Imui.widgets.number_slider.create(imui, &self.map_length_scale, .{}, key ++ .{@src()});
    }

    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "map minimum height (m): ");
        _ = Imui.widgets.number_slider.create(imui, &self.map_minimum_height, .{}, key ++ .{@src()});
    }
    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "map maximum height (m): ");
        _ = Imui.widgets.number_slider.create(imui, &self.map_maximum_height, .{}, key ++ .{@src()});
    }
    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "map height scale: ");
        _ = Imui.widgets.number_slider.create(imui, &self.map_height_scale, .{}, key ++ .{@src()});
    }

    {
        _ = imui.push_form_layout_item(key ++ .{@src()});
        defer imui.pop_layout();

        _ = Imui.widgets.label.create(imui, "modify radius: ");
        _ = Imui.widgets.number_slider.create(imui, &self.modify_radius, .{}, key ++ .{@src()});
    }
}

pub fn edit_terrain(self: *Self, terrain_renderer: *TerrainRenderer) !bool {
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

        const terrain_uv = terrain_renderer.selection_textures
            .get_value_at_position(@intCast(mouse_pos[0]), @intCast(mouse_pos[1])) catch {
                return false;
            };
        if (terrain_uv[0] < 0.0 or terrain_uv[1] < 0.0 or terrain_uv[0] > 1.0 or terrain_uv[1] > 1.0) {
            return false;
        }
        const terrain_uv_v = zm.loadArr2(terrain_uv);
    
        const heightmap_modify_center = terrain_uv_v * zm.f32x4s(heightfield_size_f32);

        const max_modify_distance_cells: f32 = (self.modify_radius / self.map_length_m) * 1.5;
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
                        const modify_radius_cells = self.modify_radius / self.map_length_m;
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
                        if (distance_to_cell <= (self.modify_radius / self.map_length_m)) {
                            self.heightmap[idx] = center_cell_value;
                        }
                    }
                }
            },
        }

        // const heightmap_image = try self.heightmap_texture.get();
        // if (heightmap_image.map(.{ .write = true, })) |mapped_texture| {
        //     defer mapped_texture.unmap();
        //     // TODO: this is incorrect, d3d11 row pitch is 128 but row length is 64. (when 16 HeightFieldSize)
        //     // probably need to do data() array access inside platform code
        //     @memcpy(mapped_texture.data(f32), self.heightmap);
        // } else |err| {
        //     std.log.err("Failed to map terrain texture: {}", .{err});
        // }
    }

    return modify_terrain != 0.0;
}
