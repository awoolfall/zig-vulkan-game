const Self = @This();

const std = @import("std");
const eng = @import("engine");

const zm = eng.zmath;
const zmesh = eng.zmesh;
const gf = eng.gfx;
const input = eng.input;
const cm = eng.camera;
const Transform = eng.Transform;
const st = @import("../selection_textures.zig");

const InstanceInfoStruct = extern struct {
    model_matrix: zm.Mat,
    colour: zm.F32x4,
    id: u32,
};

const RenderBuffers = struct {
    vertex_buffer: gf.Buffer.Ref,
    index_buffer: gf.Buffer.Ref,
    index_count: usize,

    pub fn deinit(self: *RenderBuffers) void {
        self.vertex_buffer.deinit();
        self.index_buffer.deinit();
    }
};

const RED = zm.srgbToRgb(zm.f32x4(0xF5, 0x6B, 0x4E, 0xFF) / zm.f32x4s(0xFF));
const GREEN = zm.srgbToRgb(zm.f32x4(0xB7, 0xF5, 0x4E, 0xFF) / zm.f32x4s(0xFF));
const BLUE = zm.srgbToRgb(zm.f32x4(0x4F, 0x80, 0xF5, 0xFF) / zm.f32x4s(0xFF));
const WHITE = zm.f32x4(1.0, 1.0, 1.0, 1.0);

visual_torus: RenderBuffers,
visual_cylinder: RenderBuffers,
visual_sphere: RenderBuffers,

id_torus: RenderBuffers,
id_cylinder: RenderBuffers,
id_sphere: RenderBuffers,

vertex_shader: gf.VertexShader,
pixel_shader: gf.PixelShader,
id_pixel_shader: gf.PixelShader,

instance_data_buffer: gf.Buffer.Ref,
selection_textures: st.SelectionTextures(u32),

selected_control: ?GizmoControl = null,
selected_offset: zm.F32x4 = zm.f32x4s(0.0),

rendered_perspective_matrix: zm.Mat = zm.identity(),
rendered_view_matrix: zm.Mat = zm.identity(),

pub fn deinit(self: *Self) void {
    self.visual_torus.deinit();
    self.visual_cylinder.deinit();
    self.visual_sphere.deinit();

    self.id_torus.deinit();
    self.id_cylinder.deinit();
    self.id_sphere.deinit();

    self.vertex_shader.deinit();
    self.pixel_shader.deinit();
    self.id_pixel_shader.deinit();

    self.instance_data_buffer.deinit();
    self.selection_textures.deinit();
}

pub fn init(alloc: std.mem.Allocator) !Self {
    const visual_line_width = 0.03;
    const id_line_width = 0.07;

    var visual_torus = try init_torus(visual_line_width);
    errdefer visual_torus.deinit();

    var visual_cylinder = try init_cylinder(visual_line_width);
    errdefer visual_cylinder.deinit();

    var visual_sphere = try init_sphere(visual_line_width);
    errdefer visual_sphere.deinit();

    var id_torus = try init_torus(id_line_width);
    errdefer id_torus.deinit();

    var id_cylinder = try init_cylinder(id_line_width);
    errdefer id_cylinder.deinit();

    var id_sphere = try init_sphere(visual_line_width);
    errdefer id_sphere.deinit();

    const instance_data_buffer = try gf.Buffer.init(
        @sizeOf(InstanceInfoStruct),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer instance_data_buffer.deinit();

    var selection_textures = try st.SelectionTextures(u32).init();
    errdefer selection_textures.deinit();

    var self = Self {
        .visual_torus = visual_torus,
        .visual_cylinder = visual_cylinder,
        .visual_sphere = visual_sphere,

        .id_torus = id_torus,
        .id_cylinder = id_cylinder,
        .id_sphere = id_sphere,

        .instance_data_buffer = instance_data_buffer,
        .selection_textures = selection_textures,
        .vertex_shader = undefined,
        .pixel_shader = undefined,
        .id_pixel_shader = undefined,
    };

    self.compile_shaders(alloc) catch |err| {
        std.log.err("unable to compile shaders: {}", .{err});
        return err;
    };
    errdefer {
        self.vertex_shader.deinit();
        self.pixel_shader.deinit();
        self.id_pixel_shader.deinit();
    }

    return self;
}

fn init_torus(line_width: f32) !RenderBuffers {
    const torus_shape = zmesh.Shape.initTorus(16, 64, line_width);
    defer torus_shape.deinit();

    const torus_vertex_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(torus_shape.positions),
        .{ .VertexBuffer = true, },
        .{},
    );
    errdefer torus_vertex_buffer.deinit();

    const torus_index_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(torus_shape.indices),
        .{ .IndexBuffer = true, },
        .{},
    );
    errdefer torus_index_buffer.deinit();

    return .{
        .vertex_buffer = torus_vertex_buffer,
        .index_buffer = torus_index_buffer,
        .index_count = torus_shape.indices.len,
    };
}

fn init_cylinder(line_width: f32) !RenderBuffers {
    var cylinder_shape = zmesh.Shape.initCylinder(16, 2);
    defer cylinder_shape.deinit();
    cylinder_shape.scale(line_width, line_width, 1.0);

    const cylinder_vertex_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(cylinder_shape.positions),
        .{ .VertexBuffer = true, },
        .{},
    );
    errdefer cylinder_vertex_buffer.deinit();

    const cylinder_index_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(cylinder_shape.indices),
        .{ .IndexBuffer = true, },
        .{},
    );
    errdefer cylinder_index_buffer.deinit();

    return .{
        .vertex_buffer = cylinder_vertex_buffer,
        .index_buffer = cylinder_index_buffer,
        .index_count = cylinder_shape.indices.len,
    };
}

fn init_sphere(line_width: f32) !RenderBuffers {
    var sphere_shape = zmesh.Shape.initParametricSphere(16, 16);
    defer sphere_shape.deinit();
    sphere_shape.scale(line_width * 2.0, line_width * 2.0, line_width * 2.0);

    const sphere_vertex_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(sphere_shape.positions),
        .{ .VertexBuffer = true, },
        .{},
    );
    errdefer sphere_vertex_buffer.deinit();

    const sphere_index_buffer = try gf.Buffer.init_with_data(
        std.mem.sliceAsBytes(sphere_shape.indices),
        .{ .IndexBuffer = true, },
        .{},
    );
    errdefer sphere_index_buffer.deinit();

    return .{
        .vertex_buffer = sphere_vertex_buffer,
        .index_buffer = sphere_index_buffer,
        .index_count = sphere_shape.indices.len,
    };
}

fn compile_shaders(self: *Self, alloc: std.mem.Allocator) !void {
    const shader_path = try eng.path.Path.init(alloc, .{ .ExeRelative = "../../src/gizmo/gizmo.hlsl" });
    defer shader_path.deinit();

    const new_vertex_shader = try gf.VertexShader.init_file(
        alloc,
        shader_path,
        "vs_main",
        .{
            .bindings = &.{
                .{ .binding = 0, .stride = 12, .input_rate = .Vertex, },
            },
            .attributes = &.{
                .{ .name = "POS", .location = 0, .binding = 0, .offset = 0,  .format = .F32x3, },
            },
        },
        .{},
    ); 
    errdefer new_vertex_shader.deinit();

    const new_pixel_shader = try gf.PixelShader.init_file(
        alloc,
        shader_path,
        "ps_colour_main",
        .{},
    );
    errdefer new_pixel_shader.deinit();

    const new_id_pixel_shader = try gf.PixelShader.init_file(
        alloc,
        shader_path,
        "ps_id_main",
        .{},
    );
    errdefer new_id_pixel_shader.deinit();

    self.vertex_shader = new_vertex_shader;
    self.pixel_shader = new_pixel_shader;
    self.id_pixel_shader = new_id_pixel_shader;
}

const CoordSpace = enum { local, world, };

const GizmoControl = enum(u32) {
    None = 0,
    TranslateX,
    TranslateY,
    TranslateZ,
    RotateX,
    RotateY,
    RotateZ,

    pub fn direction_world(self: GizmoControl) zm.F32x4 {
        return switch (self) {
            .TranslateX, .RotateX => zm.f32x4(1.0, 0.0, 0.0, 0.0),
            .TranslateY, .RotateY => zm.f32x4(0.0, 1.0, 0.0, 0.0),
            .TranslateZ, .RotateZ, .None => zm.f32x4(0.0, 0.0, 1.0, 0.0),
        };
    }
    pub fn direction_local(self: GizmoControl, transform: *const Transform) zm.F32x4 {
        return switch (self) {
            .TranslateX, .RotateX => transform.right_direction(),
            .TranslateY, .RotateY => transform.up_direction(),
            .TranslateZ, .RotateZ, .None => transform.forward_direction(),
        };
    }
    pub inline fn direction(self: GizmoControl, transform: *const Transform, space: CoordSpace) zm.F32x4 {
        return switch (space) {
            .local => self.direction_local(transform),
            .world => self.direction_world(),
        };
    }
};

fn sub_rotation(control: GizmoControl, base_rot: *const zm.Mat, base_translation: *const zm.Mat) zm.Mat {
    const subrot = switch (control) {
        .TranslateX, .RotateX => zm.rotationY(std.math.pi * 0.5),
        .TranslateY, .RotateY => zm.rotationX(-std.math.pi * 0.5),
        .TranslateZ, .RotateZ, .None => zm.identity(),
    };
    
    return zm.mul(
        zm.mul(subrot, base_rot.*), 
        base_translation.*
    );
}

const Ray = struct {
    origin: zm.F32x4,
    direction: zm.F32x4,
};

fn ray_out_point_on_screen_px(point_px: [2]i32, inv_perspective: zm.Mat, inv_view: zm.Mat) Ray {
    var ndc_cursor = zm.f32x4(@floatFromInt(point_px[0]), @floatFromInt(point_px[1]), 1.0, 1.0);
    ndc_cursor /= zm.f32x4(@floatFromInt(eng.get().gfx.swapchain_size()[0]), @floatFromInt(eng.get().gfx.swapchain_size()[1]), 1.0, 1.0);
    ndc_cursor *= zm.f32x4(2.0, -2.0, 1.0, 1.0);
    ndc_cursor -= zm.f32x4(1.0, -1.0, 0.0, 0.0);

    const near_ndc = zm.f32x4(ndc_cursor[0], ndc_cursor[1], 1.0, 1.0);
    const far_ndc = zm.f32x4(ndc_cursor[0], ndc_cursor[1], 0.0, 1.0);

    var near_view = zm.mul(near_ndc, inv_perspective);
    near_view /= zm.f32x4s(near_view[3]);
    var far_view = zm.mul(far_ndc, inv_perspective);
    far_view /= zm.f32x4s(far_view[3]);

    const near_world = zm.mul(near_view, inv_view);
    const far_world = zm.mul(far_view, inv_view);

    return .{
        .origin = near_world,
        .direction = zm.normalize3(far_world - near_world),
    };
}

const ClosestPointsResult = struct {
    point_on_ray1: zm.F32x4,
    point_on_ray2: zm.F32x4,
    distance: f32,
};

/// Calculates the closest points between two 3D rays in world space
pub fn closest_points_between_rays(ray1: Ray, ray2: Ray) ClosestPointsResult {
    // Ensure direction vectors are normalized
    const dir1 = zm.normalize3(ray1.direction);
    const dir2 = zm.normalize3(ray2.direction);
    
    // Calculate values needed for the solution
    const a = zm.dot3(dir1, dir1)[0]; // Should be 1.0 if normalized
    const b = zm.dot3(dir1, dir2)[0];
    const c = zm.dot3(dir2, dir2)[0]; // Should be 1.0 if normalized
    
    // Vector connecting the two ray origins
    const r = ray1.origin - ray2.origin;
    
    const d = zm.dot3(dir1, r)[0];
    const e = zm.dot3(dir2, r)[0];
    
    // Calculate denominator for the solution
    const denominator = a * c - b * b;
    
    // If denominator is close to 0, rays are nearly parallel
    if (@abs(denominator) < 0.0001) {
        // For parallel rays, we'll use a different approach
        // Project ray2's origin onto ray1 to find closest point on ray1
        const t1 = d / a;
        const point_on_ray1 = ray1.origin + (dir1 * zm.f32x4s(t1));
        
        // For the second point, project ray1's point onto ray2's direction
        const point_to_origin2 = point_on_ray1 - ray2.origin;
        const t2 = zm.dot3(point_to_origin2, dir2)[0];
        const point_on_ray2 = ray2.origin + (dir2 * zm.f32x4s(t2));
        
        // Calculate the distance between these points
        const diff = point_on_ray1 - point_on_ray2;
        const distance = zm.length3(diff)[0];
        
        return ClosestPointsResult{
            .point_on_ray1 = point_on_ray1,
            .point_on_ray2 = point_on_ray2,
            .distance = distance,
        };
    }
    
    // Calculate the parameters t1 and t2 that give the closest points
    const t1 = (b * e - c * d) / denominator;
    const t2 = (a * e - b * d) / denominator;
    
    // Calculate the closest points on each ray
    const point_on_ray1 = (ray1.origin + (dir1 * zm.f32x4s(t1)));
    const point_on_ray2 = (ray2.origin + (dir2 * zm.f32x4s(t2)));
    
    // Calculate the distance between these points
    const diff = point_on_ray1 - point_on_ray2;
    const distance = zm.length3(diff)[0];
    
    return ClosestPointsResult{
        .point_on_ray1 = point_on_ray1,
        .point_on_ray2 = point_on_ray2,
        .distance = distance,
    };
}

const Plane = struct {
    point: zm.F32x4,
    normal: zm.F32x4,
    up: zm.F32x4,
};


const RayPlaneIntersectionResult = struct {
    world_position: zm.F32x4,
    plane_coords: zm.F32x4, // x,y are coordinates in plane space, z,w unused
    hit: bool,
};

/// Calculates the intersection between a ray and a plane
pub fn ray_plane_intersection(ray: Ray, plane: Plane) RayPlaneIntersectionResult {
    // 1. Calculate if the ray and plane intersect
    const normal = zm.normalize3(plane.normal);
    const denominator = zm.dot3(normal, ray.direction)[0];
    
    // If denominator is close to 0, ray is parallel to the plane
    if (@abs(denominator) < 0.0001) {
        return RayPlaneIntersectionResult{
            .world_position = zm.f32x4(0, 0, 0, 0),
            .plane_coords = zm.f32x4(0, 0, 0, 0),
            .hit = false,
        };
    }
    
    // 2. Calculate distance from ray origin to the intersection point
    const p0_to_origin = (ray.origin - plane.point);
    const t = -zm.dot3(normal, p0_to_origin)[0] / denominator;
    
    // If t is negative, the intersection is behind the ray origin
    if (t < 0) {
        return RayPlaneIntersectionResult {
            .world_position = zm.f32x4(0, 0, 0, 0),
            .plane_coords = zm.f32x4(0, 0, 0, 0),
            .hit = false,
        };
    }
    
    // 3. Calculate the world position of the intersection
    const scaled_direction = (ray.direction * zm.f32x4s(t));
    const world_position = (ray.origin + scaled_direction);
    
    // 4. Calculate the plane's coordinate system
    // Normalize the up vector
    const up = zm.normalize3(plane.up);
    
    // Calculate the right vector (perpendicular to both normal and up)
    const right = zm.normalize3(zm.cross3(up, normal));
    
    // Recalculate up to ensure orthogonality (normal, right, and up form an orthogonal basis)
    const corrected_up = zm.normalize3(zm.cross3(normal, right));
    
    // 5. Calculate the plane coordinates
    // Vector from plane origin point to intersection
    const vector_to_intersection = (world_position - plane.point);
    
    // Project this vector onto the plane basis vectors
    const x_coord = zm.dot3(vector_to_intersection, right)[0];
    const y_coord = zm.dot3(vector_to_intersection, corrected_up)[0];
    
    return RayPlaneIntersectionResult {
        .world_position = world_position,
        .plane_coords = zm.f32x4(x_coord, y_coord, 0, 0),
        .hit = true,
    };
}

fn translate_with_cursor(self: *const Self, transform: *Transform, cursor_ray: Ray, translation_dir: zm.F32x4) void {
    const closest_points = closest_points_between_rays(cursor_ray, Ray{
        .origin = transform.position,
        .direction = translation_dir,
    });
    transform.position = closest_points.point_on_ray2 - self.selected_offset;
}

fn scale_with_cursor(self: *const Self, transform: *Transform, inv_perspective: zm.Mat, inv_view: zm.Mat, scale_dir: zm.F32x4) void {
    _ = self;
    const cursor_ray_this_frame = ray_out_point_on_screen_px(eng.get().input.cursor_position, inv_perspective, inv_view);
    const closest_point_this_frame = closest_points_between_rays(cursor_ray_this_frame, Ray{
        .origin = transform.position,
        .direction = scale_dir,
    }).point_on_ray2;

    const mouse_delta = [2]i32{@intFromFloat(eng.get().input.mouse_delta[0]), @intFromFloat(eng.get().input.mouse_delta[1])};
    const cursor_pos_last_frame = [2]i32 {
        eng.get().input.cursor_position[0] - mouse_delta[0],
        eng.get().input.cursor_position[1] - mouse_delta[1],
    };
    const cursor_ray_last_frame = ray_out_point_on_screen_px(cursor_pos_last_frame, inv_perspective, inv_view);
    const closest_point_last_frame = closest_points_between_rays(cursor_ray_last_frame, Ray{
        .origin = transform.position,
        .direction = scale_dir,
    }).point_on_ray2;

    const delta = closest_point_this_frame - closest_point_last_frame;
    const delta_length = std.math.sign(zm.dot3(delta, scale_dir)[0]) * zm.length3(delta)[0];

    transform.scale += scale_dir * zm.f32x4s(delta_length);
}

inline fn non_orthogonalized_plane_up_direction(normal: zm.F32x4) zm.F32x4 {
    return if (zm.dot3(normal, zm.f32x4(0.0, 1.0, 0.0, 0.0))[0] == 1.0) zm.f32x4(0.0, 0.0, 1.0, 0.0) else zm.f32x4(0.0, 1.0, 0.0, 0.0);
}

fn rotate_with_cursor(self: *Self, transform: *Transform, cursor_ray: Ray, rotation_normal: zm.F32x4) void {
    const plane = Plane {
        .point = transform.position,
        .normal = rotation_normal,
        .up = non_orthogonalized_plane_up_direction(rotation_normal),
    };
    const intersection = ray_plane_intersection(cursor_ray, plane);
    if (intersection.hit) {
        const normalized_plane_coords = zm.normalize3(intersection.plane_coords);
        var angle = std.math.atan2(normalized_plane_coords[1], normalized_plane_coords[0]);
        if (std.math.isNan(angle)) {
            angle = 0.0;
        }
        transform.rotation = zm.qmul(transform.rotation, zm.quatFromAxisAngle(rotation_normal, angle - self.selected_offset[0]));
        self.selected_offset[0] = angle;
    }
}

inline fn get_coord_space() CoordSpace {
    return if (eng.get().input.get_key(input.KeyCode.Control)) .local else .world;
}

pub fn update(self: *Self, transform: *Transform) bool {
    const inv_perspective = zm.inverse(self.rendered_perspective_matrix);
    const inv_view = zm.inverse(self.rendered_view_matrix);

    const coord_space = get_coord_space();
    if (eng.get().input.get_key_down(input.KeyCode.MouseLeft)) {
        self.selected_control = null;
        if (self.selection_textures.get_value_at_position(@intCast(eng.get().input.cursor_position[0]), @intCast(eng.get().input.cursor_position[1]), &eng.get().gfx)) |s| {
            self.selected_control = @as(GizmoControl, @enumFromInt(s));
            switch (self.selected_control.?) {
                .TranslateX, .TranslateY, .TranslateZ => {
                    const cursor_ray = ray_out_point_on_screen_px(eng.get().input.cursor_position, inv_perspective, inv_view);
                    const closest_points = closest_points_between_rays(cursor_ray, Ray{
                        .origin = transform.position,
                        .direction = self.selected_control.?.direction(transform, coord_space),
                    });
                    self.selected_offset = closest_points.point_on_ray2 - transform.position;
                },
                .RotateX, .RotateY, .RotateZ => {
                    const cursor_ray = ray_out_point_on_screen_px(eng.get().input.cursor_position, inv_perspective, inv_view);
                    const local_direction = self.selected_control.?.direction(transform, coord_space);
                    const plane = Plane {
                        .point = transform.position,
                        .normal = local_direction,
                        .up = non_orthogonalized_plane_up_direction(local_direction),
                    };
                    const intersection = ray_plane_intersection(cursor_ray, plane);
                    if (intersection.hit) {
                        const normalized_plane_coords = zm.normalize3(intersection.plane_coords);
                        self.selected_offset[0] = std.math.atan2(normalized_plane_coords[1], normalized_plane_coords[0]);
                        if (std.math.isNan(self.selected_offset[0])) {
                            self.selected_offset[0] = 0.0;
                        }
                    }
                },
                .None => {},
            }
        } else |_| {}
    }
    if (eng.get().input.get_key_up(input.KeyCode.MouseLeft)) {
        self.selected_control = null;
        self.selected_offset = zm.f32x4s(0.0);
    }
    if (eng.get().input.get_key(input.KeyCode.MouseLeft)) {
        if (self.selected_control) |s| {
            const cursor_ray = ray_out_point_on_screen_px(eng.get().input.cursor_position, inv_perspective, inv_view);
            switch (s) {
                .None => {},
                .TranslateX, .TranslateY, .TranslateZ => {
                    if (eng.get().input.get_key(input.KeyCode.Z)) {
                        self.scale_with_cursor(transform, inv_perspective, inv_view, s.direction(transform, coord_space));
                    } else {
                        self.translate_with_cursor(transform, cursor_ray, s.direction(transform, coord_space));
                    }
                },
                .RotateX, .RotateY, .RotateZ => {
                    self.rotate_with_cursor(transform, cursor_ray, s.direction(transform, coord_space));
                }
            }
        }
    }

    return !(self.selected_control == null or self.selected_control == .None);
}

pub fn render(
    self: *Self, 
    transform: *const Transform, 
    camera_buffer: *const gf.Buffer, 
    rtv: gf.ImageView.Ref, 
    dsv: gf.ImageView.Ref, 
    camera: *const cm.Camera
) void {
    const gfx = &eng.get().gfx;
    self.rendered_perspective_matrix = camera.generate_perspective_matrix(gfx.swapchain_aspect());
    self.rendered_view_matrix = camera.transform.generate_view_matrix();

    // recreate selection textures if size has changed
    const selection_image = self.selection_textures.texture.get() catch unreachable;
    if (selection_image.info.width != gfx.swapchain_size()[0] or selection_image.info.height != gfx.swapchain_size()[1]) {
        self.selection_textures.on_resize(gfx);
    }

    gfx.cmd_clear_depth_stencil_view(dsv, 0.0, null);
    gfx.cmd_set_render_target(&.{rtv}, dsv);

    // set shaders
    gfx.cmd_set_vertex_shader(&self.vertex_shader);

    // set render state
    gfx.cmd_set_topology(.TriangleList);
    gfx.cmd_set_rasterizer_state(.{ .FillFront = true, .FillBack = true, });

    // set shader resources
    gfx.cmd_set_constant_buffers(.Vertex, 0, &[_]*const gf.Buffer{
        camera_buffer,
        &self.instance_data_buffer,
    });
    gfx.cmd_set_constant_buffers(.Pixel, 0, &[_]*const gf.Buffer{
        camera_buffer,
        &self.instance_data_buffer,
    });

    // render visual objects
    gfx.cmd_set_pixel_shader(&self.pixel_shader);
    gfx.cmd_clear_depth_stencil_view(dsv, 0.0, null);
    self.render_objects(transform, camera, dsv, .Visual);

    // render id objects
    self.selection_textures.clear(0);
    gfx.cmd_set_render_target(&.{self.selection_textures.rtv}, dsv);
    gfx.cmd_set_pixel_shader(&self.id_pixel_shader);
    gfx.cmd_clear_depth_stencil_view(dsv, 0.0, null);
    self.render_objects(transform, camera, dsv, .Id);
}

fn render_objects(self: *Self, transform: *const Transform, camera: *const cm.Camera, dsv: gf.ImageView.Ref, ty: enum { Visual, Id }) void {
    const gfx = &eng.get().gfx;

    // set torus vertex and index buffers
    var torus_vertex_bufer: gf.Buffer = undefined;
    var torus_index_buffer: gf.Buffer = undefined;
    var torus_index_count: usize = undefined;
    switch (ty) {
        .Visual => {
            torus_vertex_bufer = self.visual_torus.vertex_buffer;
            torus_index_buffer = self.visual_torus.index_buffer;
            torus_index_count = self.visual_torus.index_count;
        },
        .Id => {
            torus_vertex_bufer = self.id_torus.vertex_buffer;
            torus_index_buffer = self.id_torus.index_buffer;
            torus_index_count = self.id_torus.index_count;
        },
    }

    gfx.cmd_set_vertex_buffers(0, &[_]gf.VertexBufferInput{
        .{ .buffer = &torus_vertex_bufer, .stride = @sizeOf([3]f32), .offset = 0, },
    });
    gfx.cmd_set_index_buffer(&torus_index_buffer, .U32, 0);

    const base_rot = if (get_coord_space() == .local) zm.matFromQuat(transform.rotation) else zm.identity();
    const distance = 10.0;
    const distance_f32x4 = zm.f32x4(distance, distance, distance, 0.0);
    const base_tra = zm.translationV(zm.normalize3(transform.position - camera.transform.position) * distance_f32x4 + camera.transform.position);

    // render white torus
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = 
                zm.mul(
                    zm.inverse(zm.lookToRh(zm.f32x4s(0.0), zm.normalize3(camera.transform.position - transform.position), zm.f32x4(0.0, 1.0, 0.0, 0.0))),
                    base_tra,
                ),
            .colour = WHITE,
            .id = @intFromEnum(GizmoControl.None),
        };
    }
    gfx.cmd_draw_indexed(@intCast(torus_index_count), 0, 0);

    // clear depth buffer so that all following controls are drawn on top of the white torus
    gfx.cmd_clear_depth_stencil_view(dsv, 0.0, null);

    // render red torus
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = sub_rotation(GizmoControl.RotateX, &base_rot, &base_tra),
            .colour = RED,
            .id = @intFromEnum(GizmoControl.RotateX),
        };
    }
    gfx.cmd_draw_indexed(@intCast(torus_index_count), 0, 0);

    // render green torus
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = sub_rotation(GizmoControl.RotateY, &base_rot, &base_tra),
            .colour = GREEN,
            .id = @intFromEnum(GizmoControl.RotateY),
        };
    }
    gfx.cmd_draw_indexed(@intCast(torus_index_count), 0, 0);

    // render blue torus
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = sub_rotation(GizmoControl.RotateZ, &base_rot, &base_tra),
            .colour = BLUE,
            .id = @intFromEnum(GizmoControl.RotateZ),
        };
    }
    gfx.cmd_draw_indexed(@intCast(torus_index_count), 0, 0);


    // set culinder vertex and index buffers
    var cylinder_vertex_buffer: gf.Buffer = undefined;
    var cylinder_index_buffer: gf.Buffer = undefined;
    var cylinder_index_count: usize = undefined;
    switch (ty) {
        .Visual => {
            cylinder_vertex_buffer = self.visual_cylinder.vertex_buffer;
            cylinder_index_buffer = self.visual_cylinder.index_buffer;
            cylinder_index_count = self.visual_cylinder.index_count;
        },
        .Id => {
            cylinder_vertex_buffer = self.id_cylinder.vertex_buffer;
            cylinder_index_buffer = self.id_cylinder.index_buffer;
            cylinder_index_count = self.id_cylinder.index_count;
        },
    }

    gfx.cmd_set_vertex_buffers(0, &[_]gf.VertexBufferInput{
        .{ .buffer = &cylinder_vertex_buffer, .stride = @sizeOf([3]f32), .offset = 0, },
    });
    gfx.cmd_set_index_buffer(&cylinder_index_buffer, .U32, 0);

    // render red cylinder
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = sub_rotation(GizmoControl.TranslateX, &base_rot, &base_tra),
            .colour = RED,
            .id = @intFromEnum(GizmoControl.TranslateX),
        };
    }
    gfx.cmd_draw_indexed(@intCast(cylinder_index_count), 0, 0);

    // render green cylinder
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = sub_rotation(GizmoControl.TranslateY, &base_rot, &base_tra),
            .colour = GREEN,
            .id = @intFromEnum(GizmoControl.TranslateY),
        };
    }
    gfx.cmd_draw_indexed(@intCast(cylinder_index_count), 0, 0);

    // render blue cylinder
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = sub_rotation(GizmoControl.TranslateZ, &base_rot, &base_tra),
            .colour = BLUE,
            .id = @intFromEnum(GizmoControl.TranslateZ),
        };
    }
    gfx.cmd_draw_indexed(@intCast(cylinder_index_count), 0, 0);


    // set sphere vertex and index buffers
    var sphere_vertex_buffer: gf.Buffer = undefined;
    var sphere_index_buffer: gf.Buffer = undefined;
    var sphere_index_count: usize = undefined;
    switch (ty) {
        .Visual => {
            sphere_vertex_buffer = self.visual_sphere.vertex_buffer;
            sphere_index_buffer = self.visual_sphere.index_buffer;
            sphere_index_count = self.visual_sphere.index_count;
        },
        .Id => {
            sphere_vertex_buffer = self.id_sphere.vertex_buffer;
            sphere_index_buffer = self.id_sphere.index_buffer;
            sphere_index_count = self.id_sphere.index_count;
        },
    }

    gfx.cmd_set_vertex_buffers(0, &[_]gf.VertexBufferInput{
        .{ .buffer = &sphere_vertex_buffer, .stride = @sizeOf([3]f32), .offset = 0, },
    });
    gfx.cmd_set_index_buffer(&sphere_index_buffer, .U32, 0);

    // render white sphere
    {
        const mapped_buffer = self.instance_data_buffer.map(.{ .write = true, }) catch unreachable;
        defer mapped_buffer.unmap();

        mapped_buffer.data(InstanceInfoStruct).* = .{
            .model_matrix = 
                base_tra
            ,
            .colour = WHITE,
            .id = @intFromEnum(GizmoControl.None),
        };
    }
    gfx.cmd_draw_indexed(@intCast(sphere_index_count), 0, 0);
}
