const std = @import("std");
const en = @import("engine");

pub const ParticleEditorData = struct {
    settings: en.particles.ParticleSystemSettings,

    pub fn reinit(self: *ParticleEditorData, entity: *en.entity.EntitySuperStruct) void {
        if (entity.app.particle_system) |ps| {
            self.settings = ps.settings;
        } else {
            self.settings = .{
                .max_particles = 100,
                .spawn_radius = 1.0,
                .spawn_rate = 1.0,
            };
        }
    }
};

pub fn particle_editor(data: *ParticleEditorData, entity: *en.entity.EntitySuperStruct, key: anytype) void {
    const imui = &en.engine().imui;

    const content_layout = imui.push_layout(.Y, key ++ .{@src()});
    defer imui.pop_layout();

    if (imui.get_widget(content_layout)) |content_layout_widget| {
        content_layout_widget.children_gap = 5;
    }

    _ = imui.label("Particle Editor");
    var should_have_particle_system = (entity.app.particle_system != null);
    const particle_system_check = imui.checkbox(&should_have_particle_system, "enable particle system", key ++ .{@src()});

    if (particle_system_check.data_changed) {
        if (should_have_particle_system) {
            entity.app.particle_system = en.particles.ParticleSystem.init(en.engine().general_allocator.allocator(), data.settings) catch unreachable;
        } else {
            entity.app.particle_system.?.deinit();
            entity.app.particle_system = null;
        }
    }

    var data_changed = false;
    defer {
        if (data_changed) {
            if (entity.app.particle_system) |*ps| {
                ps.settings = data.settings;
            }
        }
    }

    {
        _ = imui.push_layout(.X, key ++ .{@src()});
        defer imui.pop_layout();

        _ = imui.label("max particles: ");
        // if (imui.get_widget(ll.id)) |ll_widget| {
        //     ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        // }
        var max_particles: f32 = @floatFromInt(data.settings.max_particles);
        const slider = imui.number_slider(&max_particles, .{ .scale = 1.0 }, key ++ .{@src()});
        if (slider.data_changed) {
            max_particles = std.math.clamp(max_particles, 10.0, 10_000.0);
            data.settings.max_particles = @intFromFloat(max_particles);
            data_changed = true;
        }
    }
    {
        _ = imui.push_layout(.X, key ++ .{@src()});
        defer imui.pop_layout();

        _ = imui.label("shape: ");
        // TODO create combobox
    }

}

fn labeled_number_slider(
    text: []const u8, 
    value: *f32, 
    settings: en.ui.Imui.NumberSliderSettings,
    key: anytype
) void {
    const ll = en.engine().imui.push_layout(.X, key ++ .{@src()});
    if (en.engine().imui.get_widget(ll)) |ll_widget| {
        ll_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 1.0, .shrinkable_percent = 0.0 };
        ll_widget.children_gap = 4;
    }
    defer en.engine().imui.pop_layout();

    const label = en.engine().imui.label(text);
    if (en.engine().imui.get_widget(label.id)) |label_widget| {
        label_widget.semantic_size[0] = .{ .kind = .ParentPercentage, .value = 0.25, .shrinkable_percent = 0.0 };
    }
    _ = en.engine().imui.number_slider(value, settings, key ++ .{@src()});
}

