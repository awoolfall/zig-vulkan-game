const std = @import("std");
const WindowEvent = @import("window_events.zig").WindowEvent;

pub fn ExternEvent(comptime U: type) type {
    const info = @typeInfo(U).@"union";
    const n = info.fields.len;

    comptime var enum_fields: [n]std.builtin.Type.EnumField = undefined;
    comptime var union_fields: [n]std.builtin.Type.UnionField = undefined;

    inline for (info.fields, 0..) |f, i| {
        // extern unions can't hold `void`, so use a 1-byte placeholder
        const T = if (f.type == void) u8 else f.type;
        enum_fields[i] = .{ .name = f.name, .value = i };
        union_fields[i] = .{ .name = f.name, .type = T, .alignment = @alignOf(T) };
    }

    const Tag = @Type(.{
        .@"enum" = .{
            .tag_type = u32,
            .fields = &enum_fields,
            .decls = &.{},
            .is_exhaustive = false,
        },
    });

    const Payload = @Type(.{ .@"union" = .{
        .layout = .@"extern",
        .tag_type = null,
        .fields = &union_fields,
        .decls = &.{},
    } });

    return extern struct {
        const Self = @This();
        pub const Kind = Tag;
        pub const Data = Payload;

        kind: Tag,
        data: Payload,

        pub fn from_union(u: U) Self {
            switch (u) {
                inline else => |v, tag| {
                    const name = @tagName(tag);
                    return .{
                        .kind = @field(Tag, name),
                        .data = @unionInit(Payload, name, if (@TypeOf(v) == void) 0 else v),
                    };
                },
            }
        }

        /// Returns null if `kind` holds a value that isn't a known variant.
        pub fn to_union(self: Self) ?U {
            inline for (info.fields) |f| {
                if (self.kind == @field(Tag, f.name)) {
                    return @unionInit(U, f.name, if (f.type == void) {} else @field(self.data, f.name));
                }
            }
            return null;
        }
    };
}

pub const WindowEventExtern = ExternEvent(WindowEvent);
