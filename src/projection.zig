//! Projections = ROM's `relation.select(:id, :name)`.
//!
//! ROM builds a narrower struct class at runtime. zom builds it at compile
//! time with `@Struct`: `Project(User, .{ .id, .name })` is a struct with
//! only `id` and `name`, with the same types and defaults as in `User`, in
//! the order given. Reading `.email` off it is a compile error, because the
//! field does not exist.
//!
//! The primary key does not have to be selected (ROM doesn't require it
//! either): `SELECT name FROM users` is a valid query, and zom never needs
//! the key of a projected row, because `update` and `delete` go through the
//! relation's query, not through rows read from it. Select the key when you
//! need it.

const std = @import("std");

/// The struct with only `fields` of `T`, in the order given, keeping each
/// field's type, default value and alignment. `fields` is a tuple of field
/// names as enum literals, e.g. `.{ .id, .name }`. An empty tuple, an
/// unknown name or a name given twice is a compile error.
///
/// Equal arguments give the same type: `Project(T, .{ .id, .name })` called
/// twice, anywhere, returns one type. `.{ .name, .id }` is a different type.
pub fn Project(comptime T: type, comptime fields: anytype) type {
    const n = fieldCount(T, fields);
    return Projection(T, n, fieldEnums(T, n, fields));
}

/// The struct itself. It takes an array of `FieldEnum(T)` values, not the
/// caller's tuple, so the memoised arguments are plain enum values and any
/// spelling of the same field list maps to the same type.
fn Projection(comptime T: type, comptime n: usize, comptime fields: [n]std.meta.FieldEnum(T)) type {
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;
    const info = @typeInfo(T).@"struct";
    for (fields, 0..) |f, i| {
        // A `FieldEnum` value is the field's index.
        const index = @backingInt(f);
        names[i] = info.field_names[index];
        types[i] = info.field_types[index];
        attrs[i] = info.field_attrs[index];
    }
    const names_final = names;
    const types_final = types;
    const attrs_final = attrs;
    return @Struct(.auto, null, &names_final, &types_final, &attrs_final);
}

/// The length of `fields`, once it is known to be a non-empty tuple.
fn fieldCount(comptime T: type, comptime fields: anytype) usize {
    const Fields = @TypeOf(fields);
    const info = @typeInfo(Fields);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError("zom.select: fields must be a tuple of field names such as .{ .id, .name }, found `" ++
            @typeName(Fields) ++ "`");
    if (fields.len == 0)
        @compileError("zom.select: select at least one field of " ++ @typeName(T));
    return fields.len;
}

/// Checks each name in `fields` against `T` and turns them into field enums.
fn fieldEnums(comptime T: type, comptime n: usize, comptime fields: anytype) [n]std.meta.FieldEnum(T) {
    const E = std.meta.FieldEnum(T);
    var out: [n]E = undefined;
    inline for (fields, 0..) |f, i| {
        const name = switch (@typeInfo(@TypeOf(f))) {
            .enum_literal => @tagName(f),
            .@"enum" => if (@TypeOf(f) == E) @tagName(f) else notAName(f),
            else => notAName(f),
        };
        if (!@hasField(T, name))
            @compileError("zom.select: '" ++ name ++ "' is not a field of " ++ @typeName(T) ++
                " (fields: " ++ fieldList(T) ++ ")");
        for (out[0..i]) |seen| {
            if (std.mem.eql(u8, @tagName(seen), name))
                @compileError("zom.select: field '" ++ name ++ "' is selected twice");
        }
        out[i] = @field(E, name);
    }
    return out;
}

fn notAName(comptime f: anytype) noreturn {
    @compileError("zom.select: each field must be an enum literal such as .id, found `" ++
        @typeName(@TypeOf(f)) ++ "`");
}

fn fieldList(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (@typeInfo(T).@"struct".field_names, 0..) |name, i| out = out ++ (if (i == 0) "" else ", ") ++ name;
    return out;
}
