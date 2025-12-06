const Self = @This();

const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const gf = eng.gfx;
const ph = eng.physics;
const as = eng.assets;
const Camera = eng.camera.Camera;
const Terrain = @import("terrain.zig");
const Transform = eng.Transform;
const st = @import("../selection_textures.zig");
const pt = eng.path;
const FileWatcher = eng.assets.FileWatcher;

const StandardRenderer = @import("../render.zig");

const ShaderFilePath = "../../src/terrain/terrain.slang";

const CLIPMAP_QUAD_COUNT = 512;

const PushConstantData = extern struct {
    view_projection_matrix: zm.Mat,
    camera_pos: zm.F32x4, 

    origin: zm.F32x4,           // origin of the heightmap mesh

    terrain_grid_length: f32,   // vertices along each edge of grid square

    terrain_length_m: f32,      // length of the heightmap in meters
    terrain_length_scale: f32,  // length scale of the heightmap

    terrain_height_m: f32,      // difference between minimum and maximum height of the heightmap
    terrain_height_scale: f32,  // height scale of the heightmap

    clipmap_level: f32,

    // modify_cells: zm.F32x4,
    // modify_center: [2]f32 = [_]f32{0.0, 0.0},
    // modify_radius: f32 = 0.0,
    // modify_strength: f32 = 0.0,
};

const ImagesDescriptorSetData = struct {
    set: gf.DescriptorSet.Ref,
    image_view: ?gf.ImageView.Ref = null,
};

selection_textures: st.SelectionTextures([2]f32),

render_pass: gf.RenderPass.Ref,
framebuffer: gf.FrameBuffer.Ref,

shader_file_watcher: FileWatcher,
pipeline: gf.GraphicsPipeline.Ref,

sampler: gf.Sampler.Ref,

images_descriptor_layout: gf.DescriptorLayout.Ref,
images_descriptor_pool: gf.DescriptorPool.Ref,
images_descriptor_sets: std.ArrayList(ImagesDescriptorSetData),

lights_descriptor_layout: gf.DescriptorLayout.Ref,
lights_descriptor_pool: gf.DescriptorPool.Ref,
lights_descriptor_set: gf.DescriptorSet.Ref,
lights_buffer: gf.Buffer.Ref,

clipmap_mesh: ClipmapMesh,

current_frame: usize = 0,
current_terrain_index: usize = 0,

pub fn deinit(self: *Self) void {
    const general_alloc = eng.get().general_allocator;

    self.clipmap_mesh.deinit();

    self.framebuffer.deinit();
    self.pipeline.deinit();
    self.shader_file_watcher.deinit();
    self.render_pass.deinit();
    self.selection_textures.deinit();

    for (self.images_descriptor_sets.items) |s| {
        s.set.deinit();
    }
    self.images_descriptor_sets.deinit(general_alloc);
    self.images_descriptor_pool.deinit();
    self.images_descriptor_layout.deinit();

    self.lights_descriptor_set.deinit();
    self.lights_descriptor_pool.deinit();
    self.lights_descriptor_layout.deinit();
    self.lights_buffer.deinit();

    self.sampler.deinit();
}

pub fn init() !Self {
    const alloc = eng.get().general_allocator;

    const clipmap_mesh = try ClipmapMesh.init(alloc, CLIPMAP_QUAD_COUNT);
    errdefer clipmap_mesh.deinit();

    var selection_textures = try st.SelectionTextures([2]f32).init();
    errdefer selection_textures.deinit();

    const images_descriptor_layout = try gf.DescriptorLayout.init(.{
        .bindings = &.{
            gf.DescriptorBindingInfo {
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .binding = 0,
                .binding_type = .ImageView,
            },
            gf.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 1,
                .binding_type = .ImageView,
            },
            gf.DescriptorBindingInfo {
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .binding = 2,
                .binding_type = .Sampler,
            },
        },
    });
    errdefer images_descriptor_layout.deinit();

    const images_descriptor_pool = try gf.DescriptorPool.init(.{
        .max_sets = 128,
        .strategy = .{ .Layout = images_descriptor_layout, },
    });
    errdefer images_descriptor_pool.deinit();

    var images_descriptor_sets = try std.ArrayList(ImagesDescriptorSetData).initCapacity(alloc, 128);
    errdefer images_descriptor_sets.deinit(alloc);

    const lights_buffer = try gf.Buffer.init(
        @sizeOf(StandardRenderer.LightsStruct) * (16 * 16),
        .{ .ConstantBuffer = true, },
        .{ .CpuWrite = true, },
    );
    errdefer lights_buffer.deinit();

    const lights_descriptor_layout = try gf.DescriptorLayout.init(.{
        .bindings = &.{
            gf.DescriptorBindingInfo {
                .shader_stages = .{ .Pixel = true, },
                .binding = 0,
                .binding_type = .UniformBuffer,
            }
        },
    });
    errdefer lights_descriptor_layout.deinit();

    const lights_descriptor_pool = try gf.DescriptorPool.init(.{
        .max_sets = 1,
        .strategy = .{ .Layout = lights_descriptor_layout, },
    });
    errdefer lights_descriptor_pool.deinit();

    const lights_descritptor_set = try (try lights_descriptor_pool.get()).allocate_set(.{
        .layout = lights_descriptor_layout,
    });
    errdefer lights_descritptor_set.deinit();

    try (try lights_descritptor_set.get()).update(.{
        .writes = &.{
            gf.DescriptorSetUpdateWriteInfo {
                .binding = 0,
                .data = .{ .UniformBuffer = .{
                    .buffer = lights_buffer,
                } },
            },
        },
    });

    const attachments = &[_]gf.AttachmentInfo {
        gf.AttachmentInfo {
            .name = "colour",
            .format = gf.GfxState.hdr_format,
            .initial_layout = .ColorAttachmentOptimal,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .None,
        },
        gf.AttachmentInfo {
            .name = "depth",
            .format = gf.GfxState.depth_format,
            .initial_layout = .DepthStencilAttachmentOptimal,
            .final_layout = .DepthStencilAttachmentOptimal,
            .blend_type = .None,
        },
        gf.AttachmentInfo {
            .name = "selection",
            .format = st.SelectionTextures([2]f32).TextureFormat,
            .initial_layout = .Undefined,
            .final_layout = .ColorAttachmentOptimal,
            .blend_type = .None,
            .load_op = .Clear,
            .clear_value = zm.f32x4s(-1.0),
        },
    };

    const render_pass = try gf.RenderPass.init(.{
        .attachments = attachments,
        .subpasses = &.{
            gf.SubpassInfo {
                .attachments = &.{ "colour", "selection" },
                .depth_attachment = "depth",
            },
        },
        .dependencies = &.{
            gf.SubpassDependencyInfo {
                .src_subpass = null,
                .dst_subpass = 0,
                .src_access_mask = .{},
                .src_stage_mask = .{ .color_attachment_output = true, },
                .dst_access_mask = .{ .color_attachment_write = true, },
                .dst_stage_mask = .{ .color_attachment_output = true, },
            },
        },
    });
    errdefer render_pass.deinit();

    const framebuffer = try gf.FrameBuffer.init(.{
        .render_pass = render_pass,
        .attachments = &.{
            .SwapchainHDR,
            .SwapchainDepth,
            .{ .View = selection_textures.view, },
        },
    });
    errdefer framebuffer.deinit();

    const sampler = try gf.Sampler.init(.{
        .border_mode = .BorderColour,
        .border_colour = zm.f32x4s(0.0),
        .filter_min_mag = .Linear,
        .filter_mip = .Linear,
        .min_lod = 0.0,
        .max_lod = 7.0,
    });
    errdefer sampler.deinit();

    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.ShaderFilePath });
    defer path.deinit();

    const path_resolved = try path.resolve_path(alloc);
    defer alloc.free(path_resolved);

    var shader_file_watcher = try FileWatcher.init(alloc, path_resolved, 1000);
    errdefer shader_file_watcher.deinit();

    var self = Self {
        .clipmap_mesh = clipmap_mesh,

        .selection_textures = selection_textures,
        .render_pass = render_pass,
        .pipeline = undefined,
        .shader_file_watcher = shader_file_watcher,
        .framebuffer = framebuffer,
        .sampler = sampler,

        .images_descriptor_layout = images_descriptor_layout,
        .images_descriptor_pool = images_descriptor_pool,
        .images_descriptor_sets = images_descriptor_sets,

        .lights_buffer = lights_buffer,
        .lights_descriptor_layout = lights_descriptor_layout,
        .lights_descriptor_pool = lights_descriptor_pool,
        .lights_descriptor_set = lights_descritptor_set,
    };

    self.pipeline = try self.create_pipeline();
    errdefer self.pipeline.deinit();

    return self;
}

fn create_pipeline(self: *Self) !gf.GraphicsPipeline.Ref {
    const alloc = eng.get().general_allocator;

    const path = try eng.path.Path.init(alloc, .{ .ExeRelative = Self.ShaderFilePath });
    defer path.deinit();

    const path_resolved = try path.resolve_path(alloc);
    defer alloc.free(path_resolved);

    const shader_file = try std.fs.openFileAbsolute(path_resolved, .{ .mode = .read_only });
    defer shader_file.close();

    const shader_slang = try alloc.alloc(u8, try shader_file.getEndPos());
    defer alloc.free(shader_slang);

    _ = try shader_file.readAll(shader_slang);

    const shader_spirv = try eng.get().gfx.shader_manager.generate_spirv(alloc, .{
        .shader_data = shader_slang,
        .shader_entry_points = &.{
            "vs_main",
            "ps_main",
        },
        .preprocessor_macros = &.{
            .{ "CLIPMAP_QUAD_COUNT", std.fmt.comptimePrint("{}", .{ CLIPMAP_QUAD_COUNT }) },
        }
    });
    defer alloc.free(shader_spirv);

    const shader_module = try gf.ShaderModule.init(.{ .spirv_data = shader_spirv });
    defer shader_module.deinit();

    const vertex_input = try gf.VertexInput.init(.{
        .bindings = &.{
            .{ .binding = 0, .stride = 12, .input_rate = .Vertex, },
        },
        .attributes = &.{
            .{ .name = "POS",           .location = 0, .binding = 0, .offset = 0,  .format = .F32x3, },
        },
    });
    defer vertex_input.deinit();

    const pipeline = try gf.GraphicsPipeline.init(.{
        .render_pass = self.render_pass,
        .subpass_index = 0,
        .vertex_shader = .{
            .module = &shader_module,
            .entry_point = "vs_main",
        },
        .vertex_input = &vertex_input,
        .pixel_shader = .{
            .module = &shader_module,
            .entry_point = "ps_main",
        },
        .depth_test = .{ .write = true, },
        .push_constants = &.{
            gf.PushConstantLayoutInfo {
                .shader_stages = .{ .Vertex = true, .Pixel = true, },
                .offset = 0,
                .size = @sizeOf(PushConstantData),
            },
        },
        .topology = .TriangleList,
        .rasterization_fill_mode = .Fill,
        .descriptor_set_layouts = &.{
            self.lights_descriptor_layout,
            self.images_descriptor_layout,
        },
    });
    errdefer pipeline.deinit();

    return pipeline;
}

/// Render the terrain using the camera buffer
pub fn render(
    self: *Self, 
    cmd: *gf.CommandBuffer,
    camera: *const Camera,
    terrain: *const Terrain, 
    transform: Transform,
    standard_renderer: *StandardRenderer,
) void {
    if (self.shader_file_watcher.was_modified_since_last_check()) blk: {
        std.log.info("Recreating terrain shader pipeline", .{});

        const new_pipeline = self.create_pipeline() catch |err| {
            std.log.err("Unable to recreate terrain shader pipeline: {}", .{err});
            break :blk;
        };
        self.pipeline.deinit();
        self.pipeline = new_pipeline;
    }

    if (self.current_frame != gf.GfxState.get().current_frame_index()) {
        self.current_frame = gf.GfxState.get().current_frame_index();
        self.current_terrain_index = 0;
    }
    defer self.current_terrain_index += 1;

    cmd.cmd_begin_render_pass(.{
        .render_pass = self.render_pass,
        .framebuffer = self.framebuffer,
        .render_area = .full_screen_pixels(),
    });
    defer cmd.cmd_end_render_pass();

    cmd.cmd_bind_graphics_pipeline(self.pipeline);

    cmd.cmd_set_viewports(.{ .viewports = &.{ .full_screen_viewport() } });
    cmd.cmd_set_scissors(.{ .scissors = &.{ .full_screen_pixels() } });

    // Create new descriptor set if necessary
    if (self.images_descriptor_sets.items.len <= self.current_terrain_index) {
        const pool = self.images_descriptor_pool.get() catch |err| {
            std.log.warn("Unable to get terrain system images descriptor pool: {}", .{err});
            return;
        };
        const new_set = pool.allocate_set(.{ .layout = self.images_descriptor_layout, }) catch |err| {
            std.log.warn("Unable to create new terrain system images descriptor set: {}", .{err});
            return;
        };
        self.images_descriptor_sets.append(eng.get().general_allocator, .{ .set = new_set, }) catch |err| {
            std.log.warn("Unable to append new terrain system images descriptor set to list: {}", .{err});
            new_set.deinit();
            return;
        };
    }

    // Update descriptor set data if necessary
    const last_set_image_view = self.images_descriptor_sets.items[self.current_terrain_index].image_view;
    if (last_set_image_view == null or !last_set_image_view.?.id.eql(terrain.heightmap_texture_view.id)) {
        const images_set = self.images_descriptor_sets.items[self.current_terrain_index].set.get() catch |err| {
            std.log.warn("Unable to get terrain images descriptor set: {}", .{err});
            return;
        };

        images_set.update(.{
            .writes = &.{
                gf.DescriptorSetUpdateWriteInfo {
                    .binding = 0,
                    .data = .{ .ImageView = terrain.heightmap_texture_view, },
                },
                gf.DescriptorSetUpdateWriteInfo {
                    .binding = 1,
                    .data = .{ .ImageView = terrain.albedo_texture_view, },
                },
                gf.DescriptorSetUpdateWriteInfo {
                    .binding = 2,
                    .data = .{ .Sampler = self.sampler, },
                },
            },
        }) catch |err| {
            std.log.warn("Unable to update terrain system image set {}: {}", .{self.current_terrain_index, err});
        };

        self.images_descriptor_sets.items[self.current_terrain_index].image_view = terrain.heightmap_texture_view;
        std.log.info("Updated terrain texture",.{});
    }

    blk: {
        const lights_buffer = self.lights_buffer.get() catch break :blk;
        const mapped_buffer = lights_buffer.map(.{ .write = .EveryFrame, }) catch break :blk;
        defer mapped_buffer.unmap();

        const data = mapped_buffer.data_array(StandardRenderer.LightsStruct, 16 * 16);
        standard_renderer.sort_lights(
            camera.transform.position
        );
        const max_lights = @min(StandardRenderer.MAX_LIGHTS, standard_renderer.lights.items.len);
        @memcpy(data[0].lights[0..max_lights], standard_renderer.lights.items[0..max_lights]);
        // for (0..16) |i| {
        //     for (0..16) |j| {
        //         standard_renderer.sort_lights(
        //             transform.position + (grid_origin_at_camera_pos + 
        //             zm.f32x4(@as(f32, @floatFromInt(i)) - 8.0, 0.0, @as(f32, @floatFromInt(j)) - 8.0, 0.0)) * zm.f32x4s(grid_size)
        //         );
        //         const max_lights = @min(StandardRenderer.MAX_LIGHTS, standard_renderer.lights.items.len);
        //         @memcpy(data[i + (16 * j)].lights[0..max_lights], standard_renderer.lights.items[0..max_lights]);
        //     }
        // }
    }

    cmd.cmd_bind_descriptor_sets(.{
        .descriptor_sets = &.{
            self.lights_descriptor_set,
            self.images_descriptor_sets.items[self.current_terrain_index].set,
        },
    });

    cmd.cmd_bind_vertex_buffers(.{
        .buffers = &.{
            gf.VertexBufferInput {
                .buffer = self.clipmap_mesh.vertices_buffer,
            },
        }
    });

    cmd.cmd_bind_index_buffer(.{
        .index_format = .U32,
        .buffer = self.clipmap_mesh.indices_buffer,
    });

    var push_constant_data = PushConstantData {
        .view_projection_matrix = zm.mul(
            camera.transform.generate_view_matrix(),
            camera.generate_perspective_matrix(gf.GfxState.get().swapchain_aspect())
        ),
        .camera_pos = camera.transform.position,

        .origin = transform.position,

        .terrain_length_m = terrain.map_length_m,
        .terrain_length_scale = terrain.map_length_scale,

        .terrain_height_m = terrain.map_maximum_height - terrain.map_minimum_height,
        .terrain_height_scale = terrain.map_height_scale,

        .terrain_grid_length = 2048,// @as(f32, @floatFromInt(HeightFieldModelSize)),

        .clipmap_level = 1.0,

        // .modify_cells = zm.f32x4(
        //     terrain.dbg_modify_cells[0][0], 
        //     terrain.dbg_modify_cells[0][1], 
        //     terrain.dbg_modify_cells[1][0], 
        //     terrain.dbg_modify_cells[1][1]),
        // .modify_center = terrain.dbg_modify_center,
        // .modify_radius = terrain.modify_radius,
        // .modify_strength = 1.0,
    };

    // draw center grid
    cmd.cmd_push_constants(.{
        .shader_stages = .{ .Vertex = true, .Pixel = true, },
        .offset = 0,
        .data = std.mem.asBytes(&push_constant_data),
    });

    cmd.cmd_draw_indexed(.{
        .index_count = self.clipmap_mesh.full_ring_indices_count,
    });

    const CLIPMAP_LEVELS = 4;

    for (0..CLIPMAP_LEVELS) |_| {
        push_constant_data.clipmap_level += 1.0;

        cmd.cmd_push_constants(.{
            .shader_stages = .{ .Vertex = true, .Pixel = true, },
            .offset = 0,
            .data = std.mem.asBytes(&push_constant_data),
        });

        cmd.cmd_draw_indexed(.{
            .index_count = self.clipmap_mesh.outer_ring_indices_count,
        });
    }
}

// TODO improve skirt transition. Reduce quad section size by 1 and improve rounding in shader so that clipmap levels dont overlap.

const ClipmapMesh = struct {
    vertices_buffer: gf.Buffer.Ref,
    indices_buffer: gf.Buffer.Ref,
    outer_ring_indices_count: u32,
    full_ring_indices_count: u32,

    pub fn deinit(self: *const ClipmapMesh) void {
        self.vertices_buffer.deinit();
        self.indices_buffer.deinit();
    }

    pub fn init(alloc: std.mem.Allocator, side_length: u32) !ClipmapMesh {
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

        return ClipmapMesh {
            .vertices_buffer = vertices_buffer,
            .indices_buffer = indices_buffer,
            .outer_ring_indices_count = outer_ring_indices_count,
            .full_ring_indices_count = quad_indices_count + skirt_segment_vertices_count,
        };
    }
};
