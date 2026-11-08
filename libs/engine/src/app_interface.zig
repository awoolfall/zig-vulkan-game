const std = @import("std");

const WindowEventExtern = @import("os/os.zig").WindowEventExtern;

const Self = @This();

fn_init: *const fn () callconv(.c) i32,
fn_deinit: *const fn () callconv(.c) i32,
fn_register: *const fn () callconv(.c) void,
fn_update: *const fn () callconv(.c) i32,
fn_render: *const fn () callconv(.c) i32,

fn_engine_init: *const fn (?*anyopaque) callconv(.c) bool,
fn_engine_deinit: *const fn (?*anyopaque) callconv(.c) void,
fn_engine_register: *const fn (?*anyopaque) callconv(.c) void,
fn_engine_on_event: *const fn (?*anyopaque, WindowEventExtern) callconv(.c) i32,

fn_app_dll_load: *const fn (engine: ?*anyopaque) callconv(.c) void,
fn_app_dll_unload: *const fn (engine: ?*anyopaque) callconv(.c) void,

pub fn init_interface(lib: *std.DynLib) !Self {
    const fn_init = lib.lookup(@FieldType(Self, "fn_init"), "app_init") orelse return error.NoInitFunction;
    const fn_deinit = lib.lookup(@FieldType(Self, "fn_deinit"), "app_deinit") orelse return error.NoDeinitFunction;
    const fn_register = lib.lookup(@FieldType(Self, "fn_register"), "app_register") orelse return error.NoRegisterFunction;
    const fn_update = lib.lookup(@FieldType(Self, "fn_update"), "app_update") orelse return error.NoUpdateFunction;
    const fn_render = lib.lookup(@FieldType(Self, "fn_render"), "app_render") orelse return error.NoRenderFunction;

    const fn_engine_init = lib.lookup(@FieldType(Self, "fn_engine_init"), "engine_init") orelse return error.NoEngineInitFunction;
    const fn_engine_deinit = lib.lookup(@FieldType(Self, "fn_engine_deinit"), "engine_deinit") orelse return error.NoEngineDeinitFunction;
    const fn_engine_register = lib.lookup(@FieldType(Self, "fn_engine_register"), "engine_register") orelse return error.NoEngineRegisterFunction;
    const fn_engine_on_event = lib.lookup(@FieldType(Self, "fn_engine_on_event"), "engine_on_event") orelse return error.NoEngineOnEventFunction;

    const fn_app_dll_load = lib.lookup(@FieldType(Self, "fn_app_dll_load"), "engine_dll_load") orelse return error.NoDllLoadFunction;
    const fn_app_dll_unload = lib.lookup(@FieldType(Self, "fn_app_dll_unload"), "engine_dll_unload") orelse return error.NoDllUnLoadFunction;

    return Self{
        .fn_init = fn_init,
        .fn_deinit = fn_deinit,
        .fn_register = fn_register,
        .fn_update = fn_update,
        .fn_render = fn_render,

        .fn_engine_init = fn_engine_init,
        .fn_engine_deinit = fn_engine_deinit,
        .fn_engine_register = fn_engine_register,
        .fn_engine_on_event = fn_engine_on_event,

        .fn_app_dll_load = fn_app_dll_load,
        .fn_app_dll_unload = fn_app_dll_unload,
    };
}
