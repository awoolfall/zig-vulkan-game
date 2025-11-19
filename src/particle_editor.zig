const std = @import("std");
const eng = @import("engine");
const zm = eng.zmath;
const Imui = eng.ui;
const ps = eng.particles;
const es = eng.easings;

const ParticleSettingsContainer = struct {
    settings: ps.ParticleSystemSettings = .{},

    pub fn deinit(self: *ParticleSettingsContainer) void {
        _ = self;
    }

    pub fn init(alloc: std.mem.Allocator) !ParticleSettingsContainer {
        _ = alloc;
        return .{};
    }

    pub fn clone(self: *ParticleSettingsContainer, alloc: std.mem.Allocator) !ParticleSettingsContainer {
        var new_settings = try ParticleSettingsContainer.init(alloc);
        new_settings.settings = try self.settings.clone(alloc);
        return new_settings;
    }

};

pub fn particle_editor(entity: *eng.entity.EntitySuperStruct, key: anytype) void {
    const imui = &eng.get().imui;

    const panel_layout = imui.push_layout(.Y, key ++ .{@src()});
    if (imui.get_widget(panel_layout)) |w| {
        w.semantic_size[0].minimum_pixel_size = 350 * 2;
        w.children_gap = 5;
    }
    defer imui.pop_layout();

    const running_settings_container, const running_settings_state = 
        imui.get_widget_data(ParticleSettingsContainer, panel_layout) catch unreachable;
    const running_settings = &running_settings_container.settings;
    if (running_settings_state == .Init) {
        if (entity.app.particle_system) |entity_ps| {
            running_settings.* = entity_ps.settings.clone(imui.widget_allocator()) catch |err| {
                std.log.err("Unable to clone particle system settings: {}", .{err});
                unreachable;
            };
        }
    }

    const title_text = Imui.widgets.label.create(imui, "Particle System Editor");
    if (imui.get_widget(title_text.id)) |title_widget| {
        title_widget.anchor = .{ 0.5, 0.5 };
        title_widget.pivot = .{ 0.5, 0.5 };
    }

    const content_layout = imui.push_layout(.X, key ++ .{@src()});
    if (imui.get_widget(content_layout)) |content_layout_widget| {
        content_layout_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, };
        content_layout_widget.children_gap = 5;
    }
    defer imui.pop_layout();

    {
        const left_layout = imui.push_layout(.Y, key ++ .{@src()});
        if (imui.get_widget(left_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.5, .shrinkable = false, };
            w.children_gap = 5;
        }
        defer imui.pop_layout();
        var should_have_particle_system = (entity.app.particle_system != null);
        const particle_system_check = Imui.widgets.checkbox.create(imui, &should_have_particle_system, "enable particle system", key ++ .{@src()});

        if (particle_system_check.data_changed) {
            if (should_have_particle_system) {
                entity.app.particle_system = eng.particles.ParticleSystem.init(eng.get().general_allocator, running_settings.*) catch unreachable;
            } else {
                entity.app.particle_system.?.deinit();
                entity.app.particle_system = null;
            }
        }

        {
            push_row_item_layout("max particles: ", key ++ .{@src()});
            defer imui.pop_layout();

            var max_particles: f32 = @floatFromInt(running_settings.max_particles);
            const slider = Imui.widgets.number_slider.create(imui, &max_particles, .{ .scale = 1.0 }, key ++ .{@src()});
            if (slider.data_changed) {
                max_particles = std.math.clamp(max_particles, 10.0, 10_000.0);
                running_settings.max_particles = @intFromFloat(max_particles);
            }
        }
        {
            push_row_item_layout("shape: ", key ++ .{@src()});
            defer imui.pop_layout();

            const shape_combobox = Imui.widgets.combobox.create(imui, key ++ .{@src()});
            const shape_combobox_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, shape_combobox.id) catch unreachable;
            if (shape_combobox.init) {
                shape_combobox_data.can_be_default = false;

                const shape_options_fields = @typeInfo(@typeInfo(ps.ParticleShape).@"union".tag_type.?).@"enum".fields;
                inline for (shape_options_fields) |field| {
                    shape_combobox_data.append_option(imui.widget_allocator(), field.name) catch unreachable;
                }

                shape_combobox_data.selected_index = @intFromEnum(running_settings.shape);
            }
            if (shape_combobox.data_changed) {
                if (shape_combobox_data.selected_index) |si| {
                    const ParticleShapeEnum = @typeInfo(ps.ParticleShape).@"union".tag_type.?;
                    const selected_shape: ParticleShapeEnum = @enumFromInt(si);
                    switch (selected_shape) {
                        .Box => running_settings.shape = .Box,
                        .Circle => running_settings.shape = .Circle,
                        //.Texture => running_settings.shape = .{ .Texture = .{} },
                    }
                }
            }
        }
        {
            push_row_item_layout("alignment: ", key ++ .{@src()});
            defer imui.pop_layout();

            const alignment_combobox = Imui.widgets.combobox.create(imui, key ++ .{@src()});
            const alignment_combobox_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, alignment_combobox.id) catch unreachable;
            if (alignment_combobox.init) {
                alignment_combobox_data.can_be_default = false;

                const alignment_option_fields = @typeInfo(@typeInfo(ps.ParticleAlignment).@"union".tag_type.?).@"enum".fields;
                inline for (alignment_option_fields) |field| {
                    alignment_combobox_data.append_option(imui.widget_allocator(), field.name) catch unreachable;
                }

                alignment_combobox_data.selected_index = @intFromEnum(running_settings.alignment);
            }
            if (alignment_combobox.data_changed) {
                if (alignment_combobox_data.selected_index) |si| {
                    const ParticleAlignmentEnum = @typeInfo(ps.ParticleAlignment).@"union".tag_type.?;
                    const selected_alignment: ParticleAlignmentEnum = @enumFromInt(si);
                    switch (selected_alignment) {
                        .Transform => running_settings.alignment = .Transform,
                        .Billboard => running_settings.alignment = .Billboard,
                        .VelocityAligned => running_settings.alignment = .{ .VelocityAligned = 1.0 },
                    }
                }
            }
        }
        switch (running_settings.alignment) {
            .VelocityAligned => {
                push_row_item_layout("velocity align: ", key ++ .{@src()});
                defer imui.pop_layout();

                _ = Imui.widgets.number_slider.create(imui, &running_settings.alignment.VelocityAligned, .{}, key ++ .{@src()});
            },
            else => {},
        }
        {
            push_row_item_layout("spawn offset: ", key ++ .{@src()});
            defer imui.pop_layout();

            _ = Imui.widgets.number_slider.create(imui, &running_settings.spawn_offset[0], .{}, key ++ .{@src()});
            _ = Imui.widgets.number_slider.create(imui, &running_settings.spawn_offset[1], .{}, key ++ .{@src()});
            _ = Imui.widgets.number_slider.create(imui, &running_settings.spawn_offset[2], .{}, key ++ .{@src()});
        }
        {
            push_row_item_layout("spawn radius: ", key ++ .{@src()});
            defer imui.pop_layout();

            const slider = Imui.widgets.number_slider.create(imui, &running_settings.spawn_radius, .{}, key ++ .{@src()});
            if (slider.data_changed) {
                running_settings.spawn_radius = @max(running_settings.spawn_radius, 0.0);
            }
        }
        {
            push_row_item_layout("spawn rate: ", key ++ .{@src()});
            defer imui.pop_layout();

            const s0 = Imui.widgets.number_slider.create(imui, &running_settings.spawn_rate, .{}, key ++ .{@src()});
            if (s0.data_changed) {
                running_settings.spawn_rate = @max(running_settings.spawn_rate, 0.0);
            }

            _ = Imui.widgets.label.create(imui, "±");
            const sv = Imui.widgets.number_slider.create(imui, &running_settings.spawn_rate_variance, .{}, key ++ .{@src()});
            if (sv.data_changed) {
                running_settings.spawn_rate_variance = @max(running_settings.spawn_rate_variance, 0.0);
            }
        }
        {
            push_row_item_layout("burst count: ", key ++ .{@src()});
            defer imui.pop_layout();

            var burst_count: f32 = @floatFromInt(running_settings.burst_count);
            const slider = Imui.widgets.number_slider.create(imui, &burst_count, .{ .scale = 1.0 }, key ++ .{@src()});
            if (slider.data_changed) {
                running_settings.burst_count = @intFromFloat(@max(burst_count, 1.0));
            }
        }
        {
            push_row_item_layout("particle lifetime: ", key ++ .{@src()});
            defer imui.pop_layout();

            const s0 = Imui.widgets.number_slider.create(imui, &running_settings.particle_lifetime, .{}, key ++ .{@src()});
            if (s0.data_changed) {
                running_settings.particle_lifetime = @max(running_settings.particle_lifetime, 0.0);
            }

            _ = Imui.widgets.label.create(imui, "±");
            const sv = Imui.widgets.number_slider.create(imui, &running_settings.particle_lifetime_variance, .{}, key ++ .{@src()});
            if (sv.data_changed) {
                running_settings.particle_lifetime_variance = @max(running_settings.particle_lifetime_variance, 0.0);
            }
        }
        {
            push_row_item_layout("initial velocity: ", key ++ .{@src()});
            defer imui.pop_layout();

            _ = Imui.widgets.number_slider.create(imui, &running_settings.initial_velocity[0], .{}, key ++ .{@src()});
            _ = Imui.widgets.number_slider.create(imui, &running_settings.initial_velocity[1], .{}, key ++ .{@src()});
            _ = Imui.widgets.number_slider.create(imui, &running_settings.initial_velocity[2], .{}, key ++ .{@src()});
        }
    }
    {
        const right_layout = imui.push_layout(.Y, key ++ .{@src()});
        if (imui.get_widget(right_layout)) |w| {
            w.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.5, .shrinkable = false, };
            w.children_gap = 5;
        }
        defer imui.pop_layout();

        const colour_keyframes_collapsible = Imui.widgets.collapsible.create(imui, "colour keyframes", null, key ++ .{@src()});
        const colour_keyframes_collapsible_open, _ = imui.get_widget_data(bool, colour_keyframes_collapsible.id) catch .{ &false, .Cont };
        if (colour_keyframes_collapsible_open.*) {
            for (running_settings.colour.items, 0..) |*c, i| {
                {
                    push_row_item_layout("key time: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const t = Imui.widgets.number_slider.create(imui, &c.key_time, .{}, key ++ .{i, @src()});
                    if (t.data_changed) {
                        c.key_time = std.math.clamp(c.key_time, 0.0, 1.0);
                    }
                }
                {
                    push_row_item_layout("colour: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const s0 = Imui.widgets.number_slider.create(imui, &c.value[0], .{}, key ++ .{i, @src()});
                    const s1 = Imui.widgets.number_slider.create(imui, &c.value[1], .{}, key ++ .{i, @src()});
                    const s2 = Imui.widgets.number_slider.create(imui, &c.value[2], .{}, key ++ .{i, @src()});
                    const s3 = Imui.widgets.number_slider.create(imui, &c.value[3], .{}, key ++ .{i, @src()});

                    if (s0.data_changed or s1.data_changed or s2.data_changed or s3.data_changed) {
                        c.value = zm.max(c.value, zm.f32x4s(0.0));
                        c.value[3] = std.math.clamp(c.value[3], 0.0, 1.0);
                    }
                }
                {
                    push_row_item_layout("into easing: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const easing_combobox_i = Imui.widgets.combobox.create(imui, key ++ .{i, @src()});
                    const easing_combobox_i_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, easing_combobox_i.id) catch unreachable;
                    if (easing_combobox_i.init) {
                        easing_combobox_i_data.can_be_default = false;

                        const easing_option_fields = @typeInfo(es.Easing).@"enum".fields;
                        inline for (easing_option_fields) |field| {
                            easing_combobox_i_data.append_option(imui.widget_allocator(), field.name) catch unreachable;
                        }

                        easing_combobox_i_data.selected_index = @intFromEnum(c.easing_into);
                    }
                    if (easing_combobox_i.data_changed) {
                        if (easing_combobox_i_data.selected_index) |si| {
                            c.easing_into = @enumFromInt(si);
                        }
                    }
                }
            }
            {
                _ = imui.push_layout(.X, key ++ .{@src()});
                defer imui.pop_layout();

                const add_button = Imui.widgets.badge.create(imui, "add keyframe", key ++ .{@src()});
                if (add_button.clicked) {
                    running_settings.colour.append(imui.widget_allocator(), .{ .value = zm.f32x4s(1.0) }) catch |err| {
                        std.log.err("Failed to add keyframe: {}", .{err});
                    };
                }
                if (running_settings.colour.items.len != 0) {
                    const rem_button = Imui.widgets.badge.create(imui, "remove keyframe", key ++ .{@src()});
                    if (rem_button.clicked) {
                        _ = running_settings.colour.pop();
                    }
                }
            }
        }

        const scale_collapsible = Imui.widgets.collapsible.create(imui, "scale keyframes", null, key ++ .{@src()});
        const scale_collapsible_open, _ = imui.get_widget_data(bool, scale_collapsible.id) catch .{ &false, .Cont };
        if (scale_collapsible_open.*) {
            for (running_settings.scale.items, 0..) |*k, i| {
                {
                    push_row_item_layout("key time: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const t = Imui.widgets.number_slider.create(imui, &k.key_time, .{}, key ++ .{i, @src()});
                    if (t.data_changed) {
                        k.key_time = std.math.clamp(k.key_time, 0.0, 1.0);
                    }
                }
                {
                    push_row_item_layout("colour: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const s0 = Imui.widgets.number_slider.create(imui, &k.value[0], .{}, key ++ .{i, @src()});
                    const s1 = Imui.widgets.number_slider.create(imui, &k.value[1], .{}, key ++ .{i, @src()});
                    const s2 = Imui.widgets.number_slider.create(imui, &k.value[2], .{}, key ++ .{i, @src()});

                    if (s0.data_changed or s1.data_changed or s2.data_changed) {
                        k.value = zm.max(k.value, zm.f32x4s(0.0));
                    }
                }
                {
                    push_row_item_layout("into easing: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const easing_combobox_i = Imui.widgets.combobox.create(imui, key ++ .{i, @src()});
                    const easing_combobox_i_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, easing_combobox_i.id) catch unreachable;
                    if (easing_combobox_i.init) {
                        easing_combobox_i_data.can_be_default = false;

                        const easing_option_fields = @typeInfo(es.Easing).@"enum".fields;
                        inline for (easing_option_fields) |field| {
                            easing_combobox_i_data.append_option(imui.widget_allocator(), field.name) catch unreachable;
                        }

                        easing_combobox_i_data.selected_index = @intFromEnum(k.easing_into);
                    }
                    if (easing_combobox_i.data_changed) {
                        if (easing_combobox_i_data.selected_index) |si| {
                            k.easing_into = @enumFromInt(si);
                        }
                    }
                }
            }
            {
                _ = imui.push_layout(.X, key ++ .{@src()});
                defer imui.pop_layout();

                const add_button = Imui.widgets.badge.create(imui, "add keyframe", key ++ .{@src()});
                if (add_button.clicked) {
                    running_settings.scale.append(imui.widget_allocator(), .{ .value = zm.f32x4s(1.0) }) catch |err| {
                        std.log.err("Failed to add keyframe: {}", .{err});
                    };
                }
                if (running_settings.scale.items.len != 0) {
                    const rem_button = Imui.widgets.badge.create(imui, "remove keyframe", key ++ .{@src()});
                    if (rem_button.clicked) {
                        _ = running_settings.scale.pop();
                    }
                }
            }
        }

        const forces_collapsible = Imui.widgets.collapsible.create(imui, "particle forces", null, key ++ .{@src()});
        const forces_collapsible_open, _ = imui.get_widget_data(bool, forces_collapsible.id) catch .{ &false, .Cont };
        if (forces_collapsible_open.*) {
            for (running_settings.forces.items, 0..) |*f, i| {
                {
                    push_row_item_layout("force: ", key ++ .{i, @src()});
                    defer imui.pop_layout();

                    const force_combobox_i = Imui.widgets.combobox.create(imui, key ++ .{i, @src()});
                    const force_combobox_i_data, _ = imui.get_widget_data(Imui.widgets.combobox.ComboBoxState, force_combobox_i.id) catch unreachable;
                    if (force_combobox_i.init) {
                        force_combobox_i_data.can_be_default = false;

                        const force_option_fields = @typeInfo(@typeInfo(ps.ForceEnum).@"union".tag_type.?).@"enum".fields;
                        inline for (force_option_fields) |field| {
                            force_combobox_i_data.append_option(imui.widget_allocator(), field.name) catch unreachable;
                        }

                        force_combobox_i_data.selected_index = @intFromEnum(f.*);
                    }
                    if (force_combobox_i.data_changed) {
                        const ForceEnumEnum = @typeInfo(ps.ForceEnum).@"union".tag_type.?;
                        const selected_force: ForceEnumEnum = @enumFromInt(force_combobox_i_data.selected_index.?);
                        switch (selected_force) {
                            .Constant => f.* = .{ .Constant = zm.f32x4s(0.0) },
                            .ConstantRand => f.* = .{ .ConstantRand = 0.0 },
                            .Curl => f.* = .{ .Curl = 1.0 },
                            .Drag => f.* = .{ .Drag = 1.0 },
                            .Vortex => f.* = .{ .Vortex = .{ .axis = zm.f32x4s(0.0), .force = 1.0, .origin_pull = 1.0 } },
                        }
                    }
                }
                switch (f.*) {
                    .Constant => |*v| {
                        push_row_item_layout("force direction: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        _ = Imui.widgets.number_slider.create(imui, &v[0], .{}, key ++ .{i, @src()});
                        _ = Imui.widgets.number_slider.create(imui, &v[1], .{}, key ++ .{i, @src()});
                        _ = Imui.widgets.number_slider.create(imui, &v[2], .{}, key ++ .{i, @src()});
                    },
                    .ConstantRand => |*v| {
                        push_row_item_layout("strength: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        _ = Imui.widgets.number_slider.create(imui, v, .{}, key ++ .{i, @src()});
                    },
                    .Curl => |*v| {
                        push_row_item_layout("strength: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        _ = Imui.widgets.number_slider.create(imui, v, .{}, key ++ .{i, @src()});
                    },
                    .Drag => |*v| {
                        push_row_item_layout("strength: ", key ++ .{i, @src()});
                        defer imui.pop_layout();

                        _ = Imui.widgets.number_slider.create(imui, v, .{}, key ++ .{i, @src()});
                    },
                    .Vortex => |*v| {
                        {
                            push_row_item_layout("axis: ", key ++ .{i, @src()});
                            defer imui.pop_layout();

                            _ = Imui.widgets.number_slider.create(imui, &v.axis[0], .{}, key ++ .{i, @src()});
                            _ = Imui.widgets.number_slider.create(imui, &v.axis[1], .{}, key ++ .{i, @src()});
                            _ = Imui.widgets.number_slider.create(imui, &v.axis[2], .{}, key ++ .{i, @src()});
                        }
                        {
                            push_row_item_layout("force: ", key ++ .{i, @src()});
                            defer imui.pop_layout();

                            _ = Imui.widgets.number_slider.create(imui, &v.force, .{}, key ++ .{i, @src()});
                        }
                        {
                            push_row_item_layout("origin pull: ", key ++ .{i, @src()});
                            defer imui.pop_layout();

                            _ = Imui.widgets.number_slider.create(imui, &v.origin_pull, .{}, key ++ .{i, @src()});
                        }
                    },
                }
                const rem_button = Imui.widgets.badge.create(imui, "remove force", key ++ .{i, @src()});
                if (rem_button.clicked) {
                    _ = running_settings.forces.orderedRemove(i);
                }
            }
            {
                _ = imui.push_layout(.X, key ++ .{@src()});
                defer imui.pop_layout();

                const add_button = Imui.widgets.badge.create(imui, "add force", key ++ .{@src()});
                if (add_button.clicked) {
                    running_settings.forces.append(imui.widget_allocator(), .{ .Constant = zm.f32x4s(0.0) }) catch |err| {
                        std.log.err("Failed to add force: {}", .{err});
                    };
                }
            }
        }
    }

    // TODO: FIX: fix this. we cant just set settings here due to allocs. We need to know if something changed.
    // or just work on the actual settings.

    // if (entity.app.particle_system) |*eps| {
    //     eps.set_settings(running_settings) catch |err| {
    //         std.log.warn("Unable to set particle system settings: {}", .{err});
    //     };
    // }
}

fn push_row_item_layout(text: []const u8, key: anytype) void {
    const imui = &eng.get().imui;
    const xl = imui.push_layout(.X, key ++ .{@src()});
    if (imui.get_widget(xl)) |xl_widget| {
        xl_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = true, };
        xl_widget.children_gap = 4;
    }

    const shape_label = Imui.widgets.label.create(imui, text);
    if (imui.get_widget(shape_label.id)) |shape_label_widget| {
        shape_label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.3, .shrinkable = false, };
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
        ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable = false, };
        ll_widget.children_gap = 4;
    }
    defer eng.get().imui.pop_layout();

    const label = eng.get().imui.label(text);
    if (eng.get().imui.get_widget(label.id)) |label_widget| {
        label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable = false, };
    }
    _ = eng.get().imui.number_slider(value, settings, key ++ .{@src()});
}
