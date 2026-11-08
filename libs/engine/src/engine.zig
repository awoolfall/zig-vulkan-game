const std = @import("std");
const AppInterface = @import("app_interface.zig");
const eng = @import("self");
const db = @import("debug/debug.zig");
const Editor = @import("editor.zig");

const znoise = @import("znoise");
const zmesh = @import("zmesh");

const Self = @This();

const Log = std.log.scoped(.Engine);
const EnableEditor: bool = true;
const EnableDllHotReload: bool = true;

// main executable
os: eng.os.Platform,
window: eng.os.Window,

general_allocator: std.mem.Allocator,
frame_arena: std.heap.ArenaAllocator,
frame_allocator: std.mem.Allocator,

app_dll: std.DynLib,
app_interface: AppInterface,
app_dll_filewatcher: if (EnableDllHotReload) eng.assets.FileWatcher else void,

exe_path: []u8,

// shared
gfx: eng.gfx.GfxState,
time: eng.TimeState,
input: eng.input.InputState,
asset_manager: eng.assets.AssetManager,
physics: eng.physics.PhysicsSystem,
ecs: eng.ecs.GenericEcsSystem,

editor: if (EnableEditor) Editor else void,

pub fn deinit(self: *Self) void {
    self.app_interface.fn_engine_deinit(self);

    if (EnableDllHotReload) {
        self.app_dll_filewatcher.deinit();
    }
    self.app_dll.close();

    self.window.close_window();
    self.os.deinit();
    self.frame_arena.deinit();
    self.general_allocator.free(self.exe_path);
    self.general_allocator.destroy(self);
}

export fn engine_deinit(engine_opaqueptr: ?*anyopaque) void {
    const engine_ptr: *eng.Engine = @ptrCast(@alignCast(engine_opaqueptr));
    engine_ptr.deinit_shared();
}

fn deinit_shared(self: *Self) void {
    self.gfx.flush();

    std.log.info("Deinitialising app.", .{});
    _ = self.app_interface.fn_deinit();

    std.log.info("Deinitialising engine.", .{});
    // deinit ecs before unloading app shared library since it
    // relies on function pointers that may exist in that lib
    self.ecs.deinit();

    if (EnableEditor) self.editor.deinit();

    self.physics.deinit();
    self.asset_manager.deinit();
    self.gfx.deinit();
    self.input.deinit();
    self.time.deinit();
    zmesh.deinit();
}

pub fn init(alloc: std.mem.Allocator) !*Self {
    const __tracy_zone = eng.ztracy.ZoneN(@src(), "Engine init");
    defer __tracy_zone.End();

    Log.debug("Initialising engine.", .{});
    const engine = try alloc.create(Self);
    errdefer alloc.destroy(engine);

    // set the global engine pointer
    eng.set_global_engine_ptr(engine);

    engine.general_allocator = alloc;

    engine.frame_arena = std.heap.ArenaAllocator.init(engine.general_allocator);
    errdefer engine.frame_arena.deinit();
    engine.frame_allocator = engine.frame_arena.allocator();

    Log.debug("Determining executable path.", .{});
    engine.exe_path = try std.fs.selfExeDirPathAlloc(engine.general_allocator);
    engine.exe_path = try alloc.realloc(engine.exe_path, engine.exe_path.len + 1);
    engine.exe_path[engine.exe_path.len - 1] = '\\';
    Log.debug("Executable path is {s}", .{engine.exe_path});
    errdefer engine.general_allocator.free(engine.exe_path);

    Log.debug("Initialising OS Platform.", .{});
    engine.os = try eng.os.Platform.init();
    errdefer engine.os.deinit();

    Log.debug("Creating main window.", .{});
    try engine.os.create_new_window(0, 0);
    while (true) {
        const event = try engine.os.pull_event();
        switch (event) {
            .window_created => |wc| {
                engine.window = try eng.os.Window.from_window_identifier_extern(wc.window);
                break;
            },
            else => {},
        }
    }

    Log.debug("Loading App shared library.", .{});
    const app_dll_path = try std.fs.path.join(engine.general_allocator, &[_][]const u8{ engine.exe_path, "app.dll" });
    defer engine.general_allocator.free(app_dll_path);

    engine.app_dll = try std.DynLib.open(app_dll_path);
    errdefer engine.app_dll.close();

    engine.app_interface = try AppInterface.init_interface(&engine.app_dll);

    if (!engine.app_interface.fn_engine_init(engine)) {
        return error.EngineSharedInitFailed;
    }

    if (EnableDllHotReload) {
        engine.app_dll_filewatcher = try eng.assets.FileWatcher.init(engine.general_allocator, app_dll_path, 1000);
        try reload_app_dll(engine);
    } else {
        engine.app_interface.fn_engine_register(engine);
        engine.app_interface.fn_register();
    }

    Log.debug("Initialising App.", .{});
    if (engine.app_interface.fn_init() != 0) {
        return error.AppFailedInit;
    }
    errdefer engine.app_interface.fn_deinit();

    Log.debug("Finished initialising app.", .{});

    engine.gfx.flush();

    return engine;
}

export fn engine_init(engine_opaqueptr: ?*anyopaque) bool {
    const engine_ptr: *eng.Engine = @ptrCast(@alignCast(engine_opaqueptr));
    init_shared(engine_ptr) catch |err| {
        std.log.err("Engine shared init error: {}", .{err});
        return false;
    };
    return true;
}

fn init_shared(engine: *Self) !void {
    eng.set_global_engine_ptr(engine);

    zmesh.init(engine.general_allocator);
    errdefer zmesh.deinit();

    Log.debug("Initialising time.", .{});
    engine.time = eng.TimeState.init();
    errdefer engine.time.deinit();

    Log.debug("Initialising input.", .{});
    engine.input = try eng.input.InputState.init();
    errdefer engine.input.deinit();

    Log.debug("Initialising GFX.", .{});
    engine.gfx = try eng.gfx.GfxState.init(engine.general_allocator, engine.main_window());
    errdefer engine.gfx.deinit();
    try engine.gfx.init_late(engine.main_window());

    Log.debug("Initialising asset manager.", .{});
    engine.asset_manager = blk: {
        const resources_path = try std.fs.path.join(engine.general_allocator, &[_][]const u8{ engine.exe_path, "../../res" });
        defer engine.general_allocator.free(resources_path);

        break :blk try eng.assets.AssetManager.init(engine.general_allocator, resources_path);
    };
    errdefer engine.asset_manager.deinit();

    Log.debug("Initialising physics.", .{});
    engine.physics = try eng.physics.PhysicsSystem.init();
    errdefer engine.physics.deinit();

    Log.debug("Initialising ECS.", .{});
    engine.ecs = try eng.ecs.GenericEcsSystem.init(engine.general_allocator);
    errdefer engine.ecs.deinit();

    if (EnableEditor) engine.editor = try Editor.init();
    errdefer if (EnableEditor) engine.editor.deinit();

    Log.debug("Finished initialising engine.", .{});
}

export fn engine_register(engine_opaqueptr: ?*anyopaque) void {
    const engine: *eng.Engine = @ptrCast(@alignCast(engine_opaqueptr));

    inline for (.{
        eng.Imui,
        eng.Debug,
    }) |T| {
        engine.ecs.register_resource(T) catch unreachable;
    }

    inline for (eng.ecs.StandardEntityComponents) |T| {
        engine.ecs.register_component(T) catch unreachable;
    }
}

pub inline fn main_window(self: *Self) *eng.os.Window {
    return &self.window;
}

fn reload_app_dll(self: *Self) !void {
    std.log.info("Reloading app shared library.", .{});

    const app_dll_path = try std.fs.path.join(self.general_allocator, &[_][]const u8{ self.exe_path, "app.dll" });
    defer self.general_allocator.free(app_dll_path);

    var running_app_dll_path = try std.fs.path.join(self.general_allocator, &[_][]const u8{ self.exe_path, "app.running.0.dll" });
    defer self.general_allocator.free(running_app_dll_path);

    std.fs.copyFileAbsolute(app_dll_path, running_app_dll_path, .{}) catch |err| {
        switch (err) {
            error.AccessDenied => {
                self.general_allocator.free(running_app_dll_path);
                running_app_dll_path = try std.fs.path.join(self.general_allocator, &[_][]const u8{ self.exe_path, "app.running.1.dll" });

                try std.fs.copyFileAbsolute(app_dll_path, running_app_dll_path, .{});
            },
            else => return err,
        }
    };

    const reload_data = try self.general_allocator.create(DllReloadData);
    defer self.general_allocator.destroy(reload_data);
    reload_data.* = .{
        .engine = self,
    };

    self.app_interface.fn_app_dll_unload(reload_data);
    self.app_dll.close();

    self.app_dll = try std.DynLib.open(running_app_dll_path);
    errdefer self.app_dll.close();

    self.app_interface = try AppInterface.init_interface(&self.app_dll);

    self.app_interface.fn_app_dll_load(reload_data);
}

pub fn run(engine: *Self) void {
    main_loop: while (true) {
        const event = try engine.os.pull_event();

        switch (event) {
            .events_cleared => {
                if (EnableDllHotReload) {
                    if (engine.app_dll_filewatcher.was_modified_since_last_check()) {
                        engine.reload_app_dll() catch |err| {
                            std.log.err("Unable to reload app dll: {}", .{err});
                            engine.main_window().close_window();
                            break :main_loop;
                        };
                        engine.app_interface = AppInterface.init_interface(&engine.app_dll) catch |err| {
                            std.log.err("Unable to reload app dll: {}", .{err});
                            engine.main_window().close_window();
                            break :main_loop;
                        };
                    }
                }
            },
            .window_requested_close => |window_id| {
                _ = window_id;
                // @TODO handle multiple windows
                engine.gfx.platform.valid_swapchain = false; // TEMP FIX disable rendering before destroying window surface
                engine.main_window().close_window();
            },
            .window_closed => |window_id| {
                // break main loop if the closed window was the main window
                if (window_id == 0) {
                    break :main_loop;
                }
            },
            else => {},
        }

        const result = engine.app_interface.fn_engine_on_event(engine, eng.os.WindowEventExtern.from_union(event));
        if (result != 0) {
            break :main_loop;
        }

        // event deinits
        switch (event) {
            .dropped_files => |d| {
                d.deinit(engine.general_allocator);
            },
            else => {},
        }
    }
}

export fn engine_on_event(engine_opaqueptr: ?*anyopaque, event: eng.os.WindowEventExtern) i32 {
    const engine_ptr: *eng.Engine = @ptrCast(@alignCast(engine_opaqueptr));
    engine_on_event_shared(engine_ptr, event.to_union() orelse return 0) catch |err| {
        std.log.err("Engine shared failed on event: {}", .{err});
        return -1;
    };
    return 0;
}

fn engine_on_event_shared(engine: *Self, event: eng.os.WindowEvent) !void {
    switch (event) {
        .events_cleared => {
            // new frame
            eng.ztracy.FrameMark();

            // Reset the frame allocator
            if (!engine.frame_arena.reset(.retain_capacity)) {
                std.log.warn("failed to reset frame arena while retaining capacity", .{});
                _ = engine.frame_arena.reset(.free_all);
            }

            engine.time.start_new_frame();

            engine.input.start_new_frame();

            if (engine.ecs.get_resource(eng.Imui)) |imui| {
                imui.start_new_frame();
            }

            if (engine.ecs.get_resource(eng.physics.PhysicsSystem)) |physics| {
                var physics_iter = engine.ecs.query_iterator(.{ eng.ecs.TransformComponent, eng.ecs.PhysicsComponent, eng.ecs.PhysicsRuntimeComponent });
                physics.update(physics_iter.create_generic_iterator());
            }

            if (EnableEditor) {
                engine.editor.update() catch |err| {
                    std.log.err("Editor error: {}", .{err});
                    return err;
                };
            } else {
                const update_result = engine.app_interface.fn_update();
                if (update_result != 0) {
                    std.log.err("App update error: {}", .{update_result});
                    return error.AppUpdateError;
                }
            }

            const render_result = engine.app_interface.fn_render();
            if (render_result != 0) {
                std.log.err("App render error: {}", .{render_result});
                return error.AppRenderError;
            }
        },
        else => {
            // run event handlers
            engine.time.received_window_event(&event);
            engine.gfx.received_window_event(&event);
            engine.input.received_window_event(&event);
        },
    }
}

const DllReloadData = struct {
    engine: *eng.Engine,
    zphysics_global: ?eng.physics.zphy.GlobalState = null,
};

pub export fn engine_dll_unload(reload_opaqueptr: ?*anyopaque) void {
    const reload_ptr: *DllReloadData = @ptrCast(@alignCast(reload_opaqueptr));
    reload_ptr.* = .{
        .engine = eng.get(),
        .zphysics_global = eng.physics.zphy.preReload(),
    };

    eng.zmesh.deinit();
}

pub export fn engine_dll_load(reload_opaqueptr: ?*anyopaque) void {
    const reload_ptr: *DllReloadData = @ptrCast(@alignCast(reload_opaqueptr));
    eng.set_global_engine_ptr(reload_ptr.engine);
    eng.zmesh.init(reload_ptr.engine.general_allocator);

    if (reload_ptr.zphysics_global) |zphysics_global| {
        eng.physics.zphy.postReload(eng.get().general_allocator, zphysics_global);
    }

    // re-register ecs types as they generate function pointers into the dll
    reload_ptr.engine.app_interface.fn_engine_register(reload_ptr.engine);
    reload_ptr.engine.app_interface.fn_register();
}
