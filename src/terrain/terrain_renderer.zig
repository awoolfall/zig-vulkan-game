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

const StandardRenderer = @import("../render.zig");

const HeightFieldModelSize = 32;

const PushConstantData = extern struct {
    view_projection_matrix: zm.Mat,
    camera_pos: zm.F32x4, 

    origin: zm.F32x4,           // origin of the heightmap mesh

    terrain_grid_length: f32,   // vertices along each edge of grid square

    terrain_length_m: f32,      // length of the heightmap in meters
    terrain_length_scale: f32,  // length scale of the heightmap

    terrain_height_m: f32,      // difference between minimum and maximum height of the heightmap
    terrain_height_scale: f32,  // height scale of the heightmap

    __pad: [3]f32 = [3]f32{0.0, 0.0, 0.0},

    modify_cells: zm.F32x4,
    modify_center: [2]f32 = [_]f32{0.0, 0.0},
    modify_radius: f32 = 0.0,
    modify_strength: f32 = 0.0,
};

const ImagesDescriptorSetData = struct {
    set: gf.DescriptorSet.Ref,
    image_view: ?gf.ImageView.Ref = null,
};

selection_textures: st.SelectionTextures([2]f32),

render_pass: gf.RenderPass.Ref,
pipeline: gf.GraphicsPipeline.Ref,
framebuffer: gf.FrameBuffer.Ref,

sampler: gf.Sampler.Ref,

images_descriptor_layout: gf.DescriptorLayout.Ref,
images_descriptor_pool: gf.DescriptorPool.Ref,
images_descriptor_sets: std.ArrayList(ImagesDescriptorSetData),

lights_descriptor_layout: gf.DescriptorLayout.Ref,
lights_descriptor_pool: gf.DescriptorPool.Ref,
lights_descriptor_set: gf.DescriptorSet.Ref,
lights_buffer: gf.Buffer.Ref,

model: eng.mesh.Model,

current_frame: usize = 0,
current_terrain_index: usize = 0,

pub fn deinit(self: *Self) void {
    const general_alloc = eng.get().general_allocator;

    self.model.deinit();

    self.framebuffer.deinit();
    self.pipeline.deinit();
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

    var plane_model = try eng.mesh.Model.plane(alloc, HeightFieldModelSize * 2 - 2, HeightFieldModelSize * 2 - 2);
    errdefer plane_model.deinit();

    var selection_textures = try st.SelectionTextures([2]f32).init();
    errdefer selection_textures.deinit();

    // const path = try eng.path.Path.init(alloc, .{ .ExeRelative = "../../src/terrain/terrain.slang" });
    // defer path.deinit();

    // const resolved_shader_path = try path.resolve_path(alloc);
    // alloc.free(resolved_shader_path);

    // const slang_shader_file = try std.fs.openFileAbsolute(resolved_shader_path, .{ .mode = .read_only });
    // defer slang_shader_file.close();

    // const slang_shader = try alloc.alloc(u8, try slang_shader_file.getEndPos());
    // defer alloc.free(slang_shader);

    // _ = try slang_shader_file.readAll(slang_shader);

    const shader_spirv = try gf.GfxState.get().shader_manager.generate_spirv(alloc, .{
        .shader_data = @embedFile("terrain.slang"),
        .shader_entry_points = &.{
            "vs_main",
            "ps_main",
        }
    });
    defer alloc.free(shader_spirv);

    const shader_module = try gf.ShaderModule.init(.{ .spirv_data = shader_spirv });
    defer shader_module.deinit();

    const vertex_input = try gf.VertexInput.init(.{
        .bindings = &.{
            //.{ .binding = 0, .stride = 88, .input_rate = .Vertex, },
        },
        .attributes = &.{
            //.{ .name = "POS",           .location = 0, .binding = 0, .offset = 0,  .format = .F32x3, },
            // .{ .name = "NORMAL",        .location = 1, .binding = 0, .offset = 12, .format = .F32x3, },
            // .{ .name = "TANGENT",       .location = 2, .binding = 0, .offset = 24, .format = .F32x3, },
            // .{ .name = "BITANGENT",     .location = 3, .binding = 0, .offset = 36, .format = .F32x3, },
            //.{ .name = "TEXCOORD0",     .location = 1, .binding = 0, .offset = 48, .format = .F32x2, },
        },
    });
    defer vertex_input.deinit();

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

    const pipeline = try gf.GraphicsPipeline.init(.{
        .render_pass = render_pass,
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
            lights_descriptor_layout,
            images_descriptor_layout,
        },
    });
    errdefer pipeline.deinit();

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
    });
    errdefer sampler.deinit();

    const terrain_path = try pt.Path.init(eng.get().general_allocator, .{ .ExeRelative = "../../src/terrain/terrain.hlsl" });
    defer terrain_path.deinit();

    const terrain_path_abs = try terrain_path.resolve_path(alloc);
    defer alloc.free(terrain_path_abs);

    return Self {
        .model = plane_model,
        .selection_textures = selection_textures,
        .render_pass = render_pass,
        .pipeline = pipeline,
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
        .graphics_pipeline = self.pipeline,
        .descriptor_sets = &.{
            self.lights_descriptor_set,
            self.images_descriptor_sets.items[self.current_terrain_index].set,
        },
    });

    cmd.cmd_bind_vertex_buffers(.{
        .buffers = &.{
            gf.VertexBufferInput {
                .buffer = self.model.vertices_buffer,
            },
        }
    });

    cmd.cmd_bind_index_buffer(.{
        .index_format = .U32,
        .buffer = self.model.indices_buffer,
        .offset = @intCast(self.model.meshes[0].indices_offset * @sizeOf(u32)),
    });
    //const grids_to_fill_space: usize = @intFromFloat(camera.far_field * 2.0 / grid_size);
    //const grids_to_fill_space: usize = 64;

    // TODO render tiles based on camera position and viewing direction
    // TODO draw instanced
    // TODO tesellation

    const push_constant_data = PushConstantData {
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

        .modify_cells = zm.f32x4(
            terrain.dbg_modify_cells[0][0], 
            terrain.dbg_modify_cells[0][1], 
            terrain.dbg_modify_cells[1][0], 
            terrain.dbg_modify_cells[1][1]),
        .modify_center = terrain.dbg_modify_center,
        .modify_radius = terrain.modify_radius,
        .modify_strength = 1.0,
    };

    cmd.cmd_push_constants(.{
        .graphics_pipeline = self.pipeline,
        .shader_stages = .{ .Vertex = true, .Pixel = true, },
        .offset = 0,
        .data = std.mem.asBytes(&push_constant_data),
    });

    cmd.cmd_draw(.{
        .vertex_count = @as(u32, @intFromFloat(push_constant_data.terrain_grid_length * push_constant_data.terrain_grid_length)) * 6,
    });

    // cmd.cmd_draw_indexed(.{
    //     .index_count = @intCast(self.model.meshes[0].index_count),
    //     .instance_count = 64 * 64,
    // });

    // for (0..grids_to_fill_space) |rx| {
    //     const x: i32 = @as(i32, @intFromFloat(grid_origin_at_camera_pos[0])) + @as(i32, @intCast(rx)) - @as(i32, @intCast(grids_to_fill_space / 2));
    //     for (0..grids_to_fill_space) |ry| {
    //         const y: i32 = @as(i32, @intFromFloat(grid_origin_at_camera_pos[2])) + @as(i32, @intCast(ry)) - @as(i32, @intCast(grids_to_fill_space / 2));
    //
    //         const push_constant_data = PushConstantData {
    //             .view_projection_matrix = zm.mul(
    //                 camera.transform.generate_view_matrix(),
    //                 camera.generate_perspective_matrix(gf.GfxState.get().swapchain_aspect())
    //             ),
    //
    //             .origin = transform.position,
    //
    //             .map_height_scale = terrain.map_height_scale,
    //             .map_length_m = terrain.map_length_m,
    //
    //             .terrain_grid_position = [2]i32{@intCast(x), @intCast(y)},
    //             .terrain_grid_length = @as(f32, @floatFromInt(HeightFieldModelSize)),
    //             .terrain_density_m = terrain.vertex_density_m,
    //
    //             .modify_cells = zm.f32x4(
    //                 terrain.dbg_modify_cells[0][0], 
    //                 terrain.dbg_modify_cells[0][1], 
    //                 terrain.dbg_modify_cells[1][0], 
    //                 terrain.dbg_modify_cells[1][1]),
    //             .modify_center = terrain.dbg_modify_center,
    //             .modify_radius = terrain.modify_radius,
    //             .modify_strength = 1.0,
    //         };
    //
    //         cmd.cmd_push_constants(.{
    //             .graphics_pipeline = self.pipeline,
    //             .shader_stages = .{ .Vertex = true, .Pixel = true, },
    //             .offset = 0,
    //             .data = std.mem.asBytes(&push_constant_data),
    //         });
    //
    //         cmd.cmd_draw_indexed(.{
    //             .index_count = @intCast(self.model.mesh_list[0].num_indices),
    //         });
    //     }
    // }
}
