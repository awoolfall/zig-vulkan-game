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
const sr = eng.serialize;
const Transform = eng.Transform;

const HeightFieldSize = 32;

alloc: std.mem.Allocator,

heightmap_asset_id: ?as.ImageAssetId = null,
heightmap: []f32,

map_length_m: f32 = 1000.0,
map_length_scale: f32 = 1.0,

map_minimum_height: f32 = 0.0,
map_maximum_height: f32 = 100.0,
map_height_scale: f32 = 1.0,

heightmap_texture_view: gf.ImageView.Ref,

albedo_texture_view: gf.ImageView.Ref,

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
    self.heightmap_texture_view.deinit();
    self.albedo_texture_view.deinit();
    self.remove_physics_body();
    self.alloc.free(self.heightmap);
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const hmt_id = try eng.get().asset_manager.find_asset_id(as.ImageAsset, "default|terrain-texture");
    const hmt = try eng.get().asset_manager.get_asset(as.ImageAsset, hmt_id);
    
    const heightmap_texture_view = try gf.ImageView.init(.{ .image = hmt.*, .view_type = .ImageView2DArray, });
    errdefer heightmap_texture_view.deinit();

    const albedo_id = try eng.get().asset_manager.find_asset_id(as.ImageAsset, "default|terrain-albedo");
    const albedo = try eng.get().asset_manager.get_asset(as.ImageAsset, albedo_id);

    const albedo_view = try gf.ImageView.init(.{ .image = albedo.*, .view_type = .ImageView2DArray, });
    errdefer albedo_view.deinit();

    const HEIGHTMAP_SAMPLES = 512;
    const heightmap_data = try alloc.alloc(f32, HEIGHTMAP_SAMPLES * HEIGHTMAP_SAMPLES);
    errdefer alloc.free(heightmap_data);

    try compute_heightmap_samples(alloc, hmt.*, heightmap_data);

    return Self {
        .alloc = alloc,

        .heightmap_texture_view = heightmap_texture_view,
        .albedo_texture_view = albedo_view,

        .heightmap = heightmap_data,
        .physics_body_id = null,
    };
}

pub fn serialize(alloc: std.mem.Allocator, self: Self) !std.json.Value {
    var object = std.json.ObjectMap.init(alloc);
    errdefer object.deinit();

    // TODO serialize physics option. Or somehow use entity super struct physics for terrain physics
    try object.put("version", try sr.serialize_value(u32, alloc, 1));
    try object.put("heightmap_asset_id", try sr.serialize_value(?as.ImageAssetId, alloc, self.heightmap_asset_id));
    try object.put("map_length_m", try sr.serialize_value(f32, alloc, self.map_length_m));
    try object.put("map_length_scale", try sr.serialize_value(f32, alloc, self.map_length_scale));
    try object.put("map_minimum_height", try sr.serialize_value(f32, alloc, self.map_minimum_height));
    try object.put("map_maximum_height", try sr.serialize_value(f32, alloc, self.map_maximum_height));
    try object.put("map_height_scale", try sr.serialize_value(f32, alloc, self.map_height_scale));

    return std.json.Value { .object = object };
}

pub fn deserialize(alloc: std.mem.Allocator, value: std.json.Value) !Self {
    var self = try Self.init(alloc);
    errdefer self.deinit();

    const object: *const std.json.ObjectMap = switch (value) { .object => |obj| &obj, else => return error.InvalidType, };

    var version: u32 = 1;
    if (object.get("version")) |v| blk: { version = sr.deserialize_value(u32, alloc, v) catch break :blk; }
    
    if (object.get("heightmap_asset_id")) |v| blk: { self.heightmap_asset_id = sr.deserialize_value(?as.ImageAssetId, alloc, v) catch break :blk; }
    if (object.get("map_length_m")) |v| blk: { self.map_length_m = sr.deserialize_value(f32, alloc, v) catch break :blk; }
    if (object.get("map_length_scale")) |v| blk: { self.map_length_scale = sr.deserialize_value(f32, alloc, v) catch break :blk; }
    if (object.get("map_minimum_height")) |v| blk: { self.map_minimum_height = sr.deserialize_value(f32, alloc, v) catch break :blk; }
    if (object.get("map_maximum_height")) |v| blk: { self.map_maximum_height = sr.deserialize_value(f32, alloc, v) catch break :blk; }
    if (object.get("map_height_scale")) |v| blk: { self.map_height_scale = sr.deserialize_value(f32, alloc, v) catch break :blk; }

    return self;
}

fn compute_heightmap_samples(alloc: std.mem.Allocator, heightmap: gf.Image.Ref, output_buffer: []f32) !void {
    const heightmap_texture_view_non_array = try gf.ImageView.init(.{ .image = heightmap, .view_type = .ImageView2D, });
    defer heightmap_texture_view_non_array.deinit();

    const heightmap_samples = std.math.sqrt(output_buffer.len);
    if (output_buffer.len != (heightmap_samples * heightmap_samples)) {
        return error.OutputBufferDoesNotRepresentASqaure;
    }

    const heightmap_samples_string = try std.fmt.allocPrint(alloc, "{}", .{ heightmap_samples });
    defer alloc.free(heightmap_samples_string);

    const heightmap_data_storage_buffer = try gf.Buffer.init(
        @sizeOf(f32) * heightmap_samples * heightmap_samples,
        .{ .StorageBuffer = true, },
        .{ .CpuRead = true, .GpuWrite = true, },
    );
    defer heightmap_data_storage_buffer.deinit();

    const sample_shader_spirv = try gf.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("terrain_sample.slang"),
        .shader_entry_points = &.{
            "cs_sample"
        },
        .preprocessor_macros = &.{
            .{ "SAMPLES_PER_AXIS", heightmap_samples_string },
        }
    });
    defer alloc.free(sample_shader_spirv);

    const sample_shader = try gf.ShaderModule.init(.{
        .spirv_data = sample_shader_spirv,
    });
    defer sample_shader.deinit();

    const sample_descriptor_layout = try gf.DescriptorLayout.init(.{
        .bindings = &.{
            gf.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 0,
                .binding_type = .ImageView,
            },
            gf.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 1,
                .binding_type = .Sampler,
            },
            gf.DescriptorBindingInfo {
                .shader_stages = .{ .Compute = true, },
                .binding = 2,
                .binding_type = .StorageBuffer,
            },
        },
    });
    defer sample_descriptor_layout.deinit();

    const sample_descriptor_pool = try gf.DescriptorPool.init(.{ .strategy = .{ .Layout = sample_descriptor_layout, }, .max_sets = 1, });
    defer sample_descriptor_pool.deinit();

    const sample_descriptor_set = try (try sample_descriptor_pool.get()).allocate_set(.{ .layout = sample_descriptor_layout, });
    defer sample_descriptor_set.deinit();

    try (try sample_descriptor_set.get()).update(.{
        .writes = &.{
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .ImageView = heightmap_texture_view_non_array },
            },
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 1,
                .data = .{ .Sampler = gf.GfxState.get().default.sampler },
            },
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 2,
                .data = .{ .StorageBuffer = .{ .buffer = heightmap_data_storage_buffer, } },
            },
        },
    });

    const sample_compute_pipeline = try gf.ComputePipeline.init(.{
        .compute_shader = .{
            .module = &sample_shader,
            .entry_point = "cs_sample",
        },
        .descriptor_set_layouts = &.{
            sample_descriptor_layout,
        },
    });
    defer sample_compute_pipeline.deinit();

    const command_pool = try gf.CommandPool.init(.{ .queue_family = .Compute, });
    defer command_pool.deinit();

    var command_buffer = try (try command_pool.get()).allocate_command_buffer(.{ .level = .Primary, });
    defer command_buffer.deinit();

    {
        try command_buffer.cmd_begin(.{ .one_time_submit = true, }); 
        command_buffer.cmd_bind_compute_pipeline(sample_compute_pipeline);
        command_buffer.cmd_bind_descriptor_sets(.{
            .descriptor_sets = &.{
                sample_descriptor_set,
            },
        });
        command_buffer.cmd_dispatch(.{ .group_count_x = heightmap_samples / 8, .group_count_y = heightmap_samples / 8 });
        try command_buffer.cmd_end();
    }

    var sample_fence = try gf.Fence.init(.{});
    defer sample_fence.deinit();

    try gf.GfxState.get().submit_command_buffer(.{
        .command_buffers = &.{
            &command_buffer,
        },
        .fence = sample_fence,
    });
    try sample_fence.wait();

    {
        const mapped_storage_buffer = try (try heightmap_data_storage_buffer.get()).map(.{ .read = true, });
        defer mapped_storage_buffer.unmap();

        const mapped_data_array = mapped_storage_buffer.data_array(f32, heightmap_samples * heightmap_samples);
        @memcpy(output_buffer[0..(heightmap_samples * heightmap_samples)], mapped_data_array[0..(heightmap_samples * heightmap_samples)]);
    }
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
        [3]f32{
            (self.map_length_m * self.map_length_scale) / heightmap_side_length_f32,
            (self.map_maximum_height - self.map_minimum_height) * self.map_height_scale,
            (self.map_length_m * self.map_length_scale) / heightmap_side_length_f32
        }
    );
    defer scaled_shape_settings.asShapeSettings().release();

    const shape = try scaled_shape_settings.asShapeSettings().createShape();
    defer shape.release();

    const new_body = try body_interface.createAndAddBody(.{
        .shape = shape,
        .position = transform.position,// + 
        //    zm.f32x4(self.map_length_m/heightmap_side_length_f32, 0.0, self.map_length_m/heightmap_side_length_f32, 0.0) / zm.f32x4s(2.0),
        .motion_type = .static,
    }, .activate);
    errdefer body_interface.removeAndDestroyBody(new_body);

    // Remove body if it exists
    self.remove_physics_body();
    
    // apply new physics body
    self.physics_body_id = new_body;
}

pub fn editor_ui(self: *Self, entity: eng.ecs.Entity, key: anytype) void {
    const imui = &eng.get().imui;

    const container = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();
    
    if (imui.get_widget(container)) |w| {
        w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, };
        w.children_gap = 4;
    }

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
                const transform: Transform = if (eng.get().ecs.get_component(eng.entity.TransformComponent, entity)) |tc| tc.transform else .{};
                self.generate_heightmap_physics(transform) catch |err| {
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
