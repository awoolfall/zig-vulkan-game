const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const Imui = @import("engine").ui.Imui;
const ps = eng.particles;
const es = eng.easings;

pub const ParticleEditorData = struct {
    arena: std.heap.ArenaAllocator,
    settings: eng.particles.ParticleSystemSettings,

    shape_combobox: Imui.ComboBoxData,
    alignment_combobox: Imui.ComboBoxData,

    colour_keyframes_is_open: bool = false,
    scale_keyframes_is_open: bool = false,
    forces_is_open: bool = false,

    colour_easing_comboboxes: [ps.MAX_KEYFRAMES]Imui.ComboBoxData,
    scale_easing_comboboxes: [ps.MAX_KEYFRAMES]Imui.ComboBoxData,
    force_comboboxes: [ps.MAX_FORCES]Imui.ComboBoxData,

    pub fn deinit(self: *ParticleEditorData) void {
        self.arena.deinit();
    }

    pub fn init(alloc: std.mem.Allocator) ParticleEditorData {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();

        const shape_options_fields = @typeInfo(@typeInfo(ps.ParticleShape).@"union".tag_type.?).@"enum".fields;
        const shape_option_names = arena.allocator().alloc([]const u8, shape_options_fields.len) catch unreachable;
        inline for (shape_options_fields, 0..) |field, field_idx| {
            shape_option_names[field_idx] = field.name;
        }

        const shape_combobox = Imui.ComboBoxData {
            .default_text = "",
            .can_be_default = false,
            .options = shape_option_names,
        };

        const alignment_option_fields = @typeInfo(@typeInfo(ps.ParticleAlignment).@"union".tag_type.?).@"enum".fields;
        const alignment_option_names = arena.allocator().alloc([]const u8, alignment_option_fields.len) catch unreachable;
        inline for (alignment_option_fields, 0..) |field, field_idx| {
            alignment_option_names[field_idx] = field.name;
        }

        const alignment_combobox = Imui.ComboBoxData {
            .default_text = "",
            .can_be_default = false,
            .options = alignment_option_names,
        };

        const easing_option_fields = @typeInfo(es.Easing).@"enum".fields;
        const easing_option_names = arena.allocator().alloc([]const u8, easing_option_fields.len) catch unreachable;
        inline for (easing_option_fields, 0..) |field, field_idx| {
            easing_option_names[field_idx] = field.name;
        }

        const easing_combobox = Imui.ComboBoxData {
            .default_text = "",
            .can_be_default = false,
            .options = easing_option_names,
        };

        var colour_easing_comboboxes: [ps.MAX_KEYFRAMES]Imui.ComboBoxData = undefined;
        for (0..ps.MAX_KEYFRAMES) |i| {
            colour_easing_comboboxes[i] = easing_combobox;
        }

        var scale_easing_comboboxes: [ps.MAX_KEYFRAMES]Imui.ComboBoxData = undefined;
        for (0..ps.MAX_KEYFRAMES) |i| {
            scale_easing_comboboxes[i] = easing_combobox;
        }

        const force_option_fields = @typeInfo(@typeInfo(ps.ForceEnum).@"union".tag_type.?).@"enum".fields;
        const force_option_names = arena.allocator().alloc([]const u8, force_option_fields.len) catch unreachable;
        inline for (force_option_fields, 0..) |field, field_idx| {
            force_option_names[field_idx] = field.name;
        }

        const force_combobox = Imui.ComboBoxData {
            .default_text = "",
            .can_be_default = false,
            .options = force_option_names,
        };

        var force_comboboxes: [ps.MAX_FORCES]Imui.ComboBoxData = undefined;
        for (0..ps.MAX_FORCES) |i| {
            force_comboboxes[i] = force_combobox;
        }

        return ParticleEditorData {
            .arena = arena,
            .settings = .{},
            .shape_combobox = shape_combobox,
            .alignment_combobox = alignment_combobox,
            .colour_easing_comboboxes = colour_easing_comboboxes,
            .scale_easing_comboboxes = scale_easing_comboboxes,
            .force_comboboxes = force_comboboxes,
        };
    }

    pub fn reinit(self: *ParticleEditorData, entity: *eng.entity.EntitySuperStruct) void {
        if (entity.app.particle_system) |sys| {
            self.settings = sys.settings;
        } else {
            self.settings = .{
                .max_particles = 100,
                .spawn_radius = 1.0,
                .spawn_rate = 1.0,
            };
        }
    }
};

pub fn particle_editor(data: *ParticleEditorData, entity: *eng.entity.EntitySuperStruct, key: anytype) void {
    const imui = &eng.get().imui;

    const panel_layout = imui.push_layout(.Y, key ++ .{@src()});
    if (imui.get_widget(panel_layout)) |w| {
        w.semantic_size[0].minimum_pixel_size = 350 * 2;
        w.children_gap = 5;
    }
    defer imui.pop_layout();

    var data_changed = false;
    defer {
        if (data_changed) {
            if (entity.app.particle_system) |*sys| {
                sys.settings = data.settings;
            }
        }
    }

    const title_text = imui.label("Particle System Editor");
    if (imui.get_widget(title_text.id)) |title_widget| {
        title_widget.anchor = .{ 0.5, 0.5 };
        title_widget.pivot = .{ 0.5, 0.5 };
    }

    const content_layout = imui.push_layout(.X, key ++ .{@src()});
    if (imui.get_widget(content_layout)) |content_layout_widget| {
        content_layout_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0 };
        content_layout_widget.children_gap = 5;
    }
    defer imui.pop_layout();

    {
        const left_layout = imui.push_layout(.Y, key ++ .{@src()});
        if (imui.get_widget(left_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.5, .shrinkable_percent = 0.0 };
            w.children_gap = 5;
        }
        defer imui.pop_layout();
        var should_have_particle_system = (entity.app.particle_system != null);
        const particle_system_check = imui.checkbox(&should_have_particle_system, "enable particle system", key ++ .{@src()});

        if (particle_system_check.data_changed) {
            if (should_have_particle_system) {
                entity.app.particle_system = eng.particles.ParticleSystem.init(eng.get().general_allocator, data.settings) catch unreachable;
            } else {
                entity.app.particle_system.?.deinit();
                entity.app.particle_system = null;
            }
        }

        {
            push_row_item_layout("max particles: ", key ++ .{@src()});
            defer imui.pop_layout();

            var max_particles: f32 = @floatFromInt(data.settings.max_particles);
            const slider = imui.number_slider(&max_particles, .{ .scale = 1.0 }, key ++ .{@src()});
            if (slider.data_changed) {
                max_particles = std.math.clamp(max_particles, 10.0, 10_000.0);
                data.settings.max_particles = @intFromFloat(max_particles);
                data_changed = true;
            }
        }
        {
            push_row_item_layout("shape: ", key ++ .{@src()});
            defer imui.pop_layout();

            data.shape_combobox.selected_index = @intFromEnum(data.settings.shape);
            const shape_combobox = imui.combobox(&data.shape_combobox, key ++ .{@src()});
            if (shape_combobox.data_changed) {
                if (data.shape_combobox.selected_index) |si| {
                    const ParticleShapeEnum = @typeInfo(ps.ParticleShape).@"union".tag_type.?;
                    const selected_shape: ParticleShapeEnum = @enumFromInt(si);
                    switch (selected_shape) {
                        .Box => data.settings.shape = .Box,
                        .Circle => data.settings.shape = .Circle,
                        //.Texture => data.settings.shape = .{ .Texture = .{} },
                    }
                    data_changed = true;
                }
            }
        }
        {
            push_row_item_layout("alignment: ", key ++ .{@src()});
            defer imui.pop_layout();

            data.alignment_combobox.selected_index = @intFromEnum(data.settings.alignment);
            const combobox = imui.combobox(&data.alignment_combobox, key ++ .{@src()});
            if (combobox.data_changed) {
                if (data.alignment_combobox.selected_index) |si| {
                    const ParticleAlignmentEnum = @typeInfo(ps.ParticleAlignment).@"union".tag_type.?;
                    const selected_alignment: ParticleAlignmentEnum = @enumFromInt(si);
                    switch (selected_alignment) {
                        .Transform => data.settings.alignment = .Transform,
                        .Billboard => data.settings.alignment = .Billboard,
                        .VelocityAligned => data.settings.alignment = .{ .VelocityAligned = 1.0 },
                    }
                    data_changed = true;
                }
            }
        }
        switch (data.settings.alignment) {
            .VelocityAligned => {
                push_row_item_layout("velocity align: ", key ++ .{@src()});
                defer imui.pop_layout();

                const s0 = imui.number_slider(&data.settings.alignment.VelocityAligned, .{}, key ++ .{@src()});
                if (s0.data_changed) {
                    data_changed = true;
                }
            },
            else => {},
        }
        {
            push_row_item_layout("spawn offset: ", key ++ .{@src()});
            defer imui.pop_layout();

            const s0 = imui.number_slider(&data.settings.spawn_offset[0], .{}, key ++ .{@src()});
            const s1 = imui.number_slider(&data.settings.spawn_offset[1], .{}, key ++ .{@src()});
            const s2 = imui.number_slider(&data.settings.spawn_offset[2], .{}, key ++ .{@src()});

            if (s0.data_changed or s1.data_changed or s2.data_changed) {
                data_changed = true;
            }
        }
        {
            push_row_item_layout("spawn radius: ", key ++ .{@src()});
            defer imui.pop_layout();

            const slider = imui.number_slider(&data.settings.spawn_radius, .{}, key ++ .{@src()});
            if (slider.data_changed) {
                data.settings.spawn_radius = @max(data.settings.spawn_radius, 0.0);
                data_changed = true;
            }
        }
        {
            push_row_item_layout("spawn rate: ", key ++ .{@src()});
            defer imui.pop_layout();

            const s0 = imui.number_slider(&data.settings.spawn_rate, .{}, key ++ .{@src()});
            if (s0.data_changed) {
                data.settings.spawn_rate = @max(data.settings.spawn_rate, 0.0);
                data_changed = true;
            }

            _ = imui.label("±");
            const sv = imui.number_slider(&data.settings.spawn_rate_variance, .{}, key ++ .{@src()});
            if (sv.data_changed) {
                data.settings.spawn_rate_variance = @max(data.settings.spawn_rate_variance, 0.0);
                data_changed = true;
            }
        }
        {
            push_row_item_layout("burst count: ", key ++ .{@src()});
            defer imui.pop_layout();

            var burst_count: f32 = @floatFromInt(data.settings.burst_count);
            const slider = imui.number_slider(&burst_count, .{ .scale = 1.0 }, key ++ .{@src()});
            if (slider.data_changed) {
                data.settings.burst_count = @intFromFloat(@max(burst_count, 1.0));
                data_changed = true;
            }
        }
        {
            push_row_item_layout("particle lifetime: ", key ++ .{@src()});
            defer imui.pop_layout();

            const s0 = imui.number_slider(&data.settings.particle_lifetime, .{}, key ++ .{@src()});
            if (s0.data_changed) {
                data.settings.particle_lifetime = @max(data.settings.particle_lifetime, 0.0);
                data_changed = true;
            }

            _ = imui.label("±");
            const sv = imui.number_slider(&data.settings.particle_lifetime_variance, .{}, key ++ .{@src()});
            if (sv.data_changed) {
                data.settings.particle_lifetime_variance = @max(data.settings.particle_lifetime_variance, 0.0);
                data_changed = true;
            }
        }
        {
            push_row_item_layout("initial velocity: ", key ++ .{@src()});
            defer imui.pop_layout();

            const s0 = imui.number_slider(&data.settings.initial_velocity[0], .{}, key ++ .{@src()});
            const s1 = imui.number_slider(&data.settings.initial_velocity[1], .{}, key ++ .{@src()});
            const s2 = imui.number_slider(&data.settings.initial_velocity[2], .{}, key ++ .{@src()});

            if (s0.data_changed or s1.data_changed or s2.data_changed) {
                data_changed = true;
            }
        }
    }
    {
        const right_layout = imui.push_layout(.Y, key ++ .{@src()});
        if (imui.get_widget(right_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.5, .shrinkable_percent = 0.0 };
            w.children_gap = 5;
        }
        defer imui.pop_layout();

        _ = imui.collapsible(&data.colour_keyframes_is_open, "colour keyframes", key ++ .{@src()});
        if (data.colour_keyframes_is_open) {
            for (data.settings.colour.slice(), 0..) |*c, i| {
                {
                    push_row_item_layout("key time: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const t = imui.number_slider(&c.key_time, .{}, key ++ .{i, @src()});
                    if (t.data_changed) {
                        c.key_time = std.math.clamp(c.key_time, 0.0, 1.0);
                        data_changed = true;
                    }
                }
                {
                    push_row_item_layout("colour: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const s0 = imui.number_slider(&c.value[0], .{}, key ++ .{i, @src()});
                    const s1 = imui.number_slider(&c.value[1], .{}, key ++ .{i, @src()});
                    const s2 = imui.number_slider(&c.value[2], .{}, key ++ .{i, @src()});
                    const s3 = imui.number_slider(&c.value[3], .{}, key ++ .{i, @src()});

                    if (s0.data_changed or s1.data_changed or s2.data_changed or s3.data_changed) {
                        c.value = zm.max(c.value, zm.f32x4s(0.0));
                        c.value[3] = std.math.clamp(c.value[3], 0.0, 1.0);
                        data_changed = true;
                    }
                }
                {
                    push_row_item_layout("into easing: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    data.colour_easing_comboboxes[i].selected_index = @intFromEnum(c.easing_into);
                    const easing_combobox = imui.combobox(&data.colour_easing_comboboxes[i], key ++ .{i, @src()});
                    if (easing_combobox.data_changed) {
                        if (data.colour_easing_comboboxes[i].selected_index) |si| {
                            c.easing_into = @enumFromInt(si);
                            data_changed = true;
                        }
                    }
                }
            }
            {
                _ = imui.push_layout(.X, key ++ .{@src()});
                defer imui.pop_layout();

                const add_button = imui.badge("add keyframe", key ++ .{@src()});
                if (add_button.clicked) {
                    data.settings.colour.append(.{ .value = zm.f32x4s(1.0) }) catch |err| {
                        std.log.err("Failed to add keyframe: {}", .{err});
                    };
                    data_changed = true;
                }
                if (data.settings.colour.len != 0) {
                    const rem_button = imui.badge("remove keyframe", key ++ .{@src()});
                    if (rem_button.clicked) {
                        _ = data.settings.colour.pop();
                        data_changed = true;
                    }
                }
            }
        }
        _ = imui.collapsible(&data.scale_keyframes_is_open, "scale keyframes", key ++ .{@src()});
        if (data.scale_keyframes_is_open) {
            for (data.settings.scale.slice(), 0..) |*k, i| {
                {
                    push_row_item_layout("key time: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const t = imui.number_slider(&k.key_time, .{}, key ++ .{i, @src()});
                    if (t.data_changed) {
                        k.key_time = std.math.clamp(k.key_time, 0.0, 1.0);
                        data_changed = true;
                    }
                }
                {
                    push_row_item_layout("colour: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const s0 = imui.number_slider(&k.value[0], .{}, key ++ .{i, @src()});
                    const s1 = imui.number_slider(&k.value[1], .{}, key ++ .{i, @src()});
                    const s2 = imui.number_slider(&k.value[2], .{}, key ++ .{i, @src()});

                    if (s0.data_changed or s1.data_changed or s2.data_changed) {
                        k.value = zm.max(k.value, zm.f32x4s(0.0));
                        data_changed = true;
                    }
                }
                {
                    push_row_item_layout("into easing: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    data.scale_easing_comboboxes[i].selected_index = @intFromEnum(k.easing_into);
                    const easing_combobox = imui.combobox(&data.scale_easing_comboboxes[i], key ++ .{i, @src()});
                    if (easing_combobox.data_changed) {
                        if (data.scale_easing_comboboxes[i].selected_index) |si| {
                            k.easing_into = @enumFromInt(si);
                            data_changed = true;
                        }
                    }
                }
            }
            {
                _ = imui.push_layout(.X, key ++ .{@src()});
                defer imui.pop_layout();

                const add_button = imui.badge("add keyframe", key ++ .{@src()});
                if (add_button.clicked) {
                    data.settings.scale.append(.{ .value = zm.f32x4s(1.0) }) catch |err| {
                        std.log.err("Failed to add keyframe: {}", .{err});
                    };
                    data_changed = true;
                }
                if (data.settings.scale.len != 0) {
                    const rem_button = imui.badge("remove keyframe", key ++ .{@src()});
                    if (rem_button.clicked) {
                        _ = data.settings.scale.pop();
                        data_changed = true;
                    }
                }
            }
        }
        _ = imui.collapsible(&data.forces_is_open, "particle forces", key ++ .{@src()});
        if (data.forces_is_open) {
            for (data.settings.forces.slice(), 0..) |*f, i| {
                {
                    push_row_item_layout("force: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    data.force_comboboxes[i].selected_index = @intFromEnum(f.*);
                    const force_combobox = imui.combobox(&data.force_comboboxes[i], key ++ .{i, @src()});
                    if (force_combobox.data_changed) {
                        const ForceEnumEnum = @typeInfo(ps.ForceEnum).@"union".tag_type.?;
                        const selected_force: ForceEnumEnum = @enumFromInt(data.force_comboboxes[i].selected_index.?);
                        switch (selected_force) {
                            .Constant => f.* = .{ .Constant = zm.f32x4s(0.0) },
                            .ConstantRand => f.* = .{ .ConstantRand = 0.0 },
                            .Curl => f.* = .{ .Curl = 1.0 },
                            .Drag => f.* = .{ .Drag = 1.0 },
                            .Vortex => f.* = .{ .Vortex = .{ .axis = zm.f32x4s(0.0), .force = 1.0, .origin_pull = 1.0 } },
                        }
                        data_changed = true;
                    }
                }
                switch (f.*) {
                    .Constant => |*v| {
                        push_row_item_layout("force direction: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        const s0 = imui.number_slider(&v[0], .{}, key ++ .{i, @src()});
                        const s1 = imui.number_slider(&v[1], .{}, key ++ .{i, @src()});
                        const s2 = imui.number_slider(&v[2], .{}, key ++ .{i, @src()});

                        if (s0.data_changed or s1.data_changed or s2.data_changed) {
                            data_changed = true;
                        }
                    },
                    .ConstantRand => |*v| {
                        push_row_item_layout("strength: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        const s0 = imui.number_slider(v, .{}, key ++ .{i, @src()});

                        if (s0.data_changed) {
                            data_changed = true;
                        }
                    },
                    .Curl => |*v| {
                        push_row_item_layout("strength: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        const s0 = imui.number_slider(v, .{}, key ++ .{i, @src()});

                        if (s0.data_changed) {
                            data_changed = true;
                        }
                    },
                    .Drag => |*v| {
                        push_row_item_layout("strength: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        const s0 = imui.number_slider(v, .{}, key ++ .{i, @src()});

                        if (s0.data_changed) {
                            data_changed = true;
                        }
                    },
                    .Vortex => |*v| {
                        {
                            push_row_item_layout("axis: ", key ++ .{i, @src()});
                            defer imui.pop_layout();

                            const s0 = imui.number_slider(&v.axis[0], .{}, key ++ .{i, @src()});
                            const s1 = imui.number_slider(&v.axis[1], .{}, key ++ .{i, @src()});
                            const s2 = imui.number_slider(&v.axis[2], .{}, key ++ .{i, @src()});

                            if (s0.data_changed or s1.data_changed or s2.data_changed) {
                                data_changed = true;
                            }
                        }
                        {
                            push_row_item_layout("force: ", key ++ .{i, @src()});
                            defer imui.pop_layout();

                            const s3 = imui.number_slider(&v.force, .{}, key ++ .{i, @src()});

                            if (s3.data_changed) {
                                data_changed = true;
                            }
                        }
                        {
                            push_row_item_layout("origin pull: ", key ++ .{i, @src()});
                            defer imui.pop_layout();

                            const s4 = imui.number_slider(&v.origin_pull, .{}, key ++ .{i, @src()});

                            if (s4.data_changed) {
                                data_changed = true;
                            }
                        }
                    },
                }
                const rem_button = imui.badge("remove force", key ++ .{i, @src()});
                if (rem_button.clicked) {
                    _ = data.settings.forces.orderedRemove(i);
                    data_changed = true;
                }
            }
            {
                _ = imui.push_layout(.X, key ++ .{@src()});
                defer imui.pop_layout();

                const add_button = imui.badge("add force", key ++ .{@src()});
                if (add_button.clicked) {
                    data.settings.forces.append(.{ .Constant = zm.f32x4s(0.0) }) catch |err| {
                        std.log.err("Failed to add force: {}", .{err});
                    };
                    data_changed = true;
                }
            }
        }
    }
}

fn push_row_item_layout(text: []const u8, key: anytype) void {
    const imui = &eng.get().imui;
    const xl = imui.push_layout(.X, key ++ .{@src()});
    if (imui.get_widget(xl)) |xl_widget| {
        xl_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 1.0, };
        xl_widget.children_gap = 4;
    }

    const shape_label = imui.label(text);
    if (imui.get_widget(shape_label.id)) |shape_label_widget| {
        shape_label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.3, .shrinkable_percent = 0.0, };
    }
}

fn labeled_number_slider(
    text: []const u8, 
    value: *f32, 
    settings: eng.ui.Imui.NumberSliderSettings,
    key: anytype
) void {
    const ll = eng.get().imui.push_layout(.X, key ++ .{@src()});
    if (eng.get().imui.get_widget(ll)) |ll_widget| {
        ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        ll_widget.children_gap = 4;
    }
    defer eng.get().imui.pop_layout();

    const label = eng.get().imui.label(text);
    if (eng.get().imui.get_widget(label.id)) |label_widget| {
        label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable_percent = 0.0 };
    }
    _ = eng.get().imui.number_slider(value, settings, key ++ .{@src()});
}

