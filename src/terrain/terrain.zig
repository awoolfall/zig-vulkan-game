const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;
const path = eng.path;
const Transform = eng.Transform;

const HeightFieldSize = 16;

pub const Descriptor = struct {
    enable_physics: bool = true,
    terrain_size: [2]f32 = .{ 16.0, 16.0 },
};

alloc: std.mem.Allocator,

terrain_size: [2]f32,

heightmap: []f32,

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
            const u: f32 = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(HeightFieldSize - 1));
            const v: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(HeightFieldSize - 1));
            heightmap_data[y * HeightFieldSize + x] = std.math.sin(u * std.math.pi * 2.0) * std.math.sin(v * std.math.pi * 2.0);
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
        .terrain_size = desc.terrain_size,
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
        .terrain_size = self.terrain_size,
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

    const shape = try shape_settings.createShape();
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

        _ = imui.label("size: ");
        _ = imui.number_slider(&self.terrain_size[0], .{}, key ++ .{@src()});
        _ = imui.number_slider(&self.terrain_size[1], .{}, key ++ .{@src()});
    }
}
