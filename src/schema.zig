//! Schema = ROM's `schema(:users) do ... end`.
//!
//! The tuple struct is the attribute list; Zig's type system already gives
//! us types, optionality (`?T`) and defaults, so the schema only adds the
//! dataset name and the primary key.

const std = @import("std");

pub fn Schema(
    comptime T: type,
    comptime dataset_name: []const u8,
    comptime pk: std.meta.FieldEnum(T),
) type {
    if (@typeInfo(T) != .@"struct")
        @compileError("zom.Schema: tuple type must be a struct, got " ++ @typeName(T));

    return struct {
        pub const Tuple = T;
        pub const name = dataset_name;
        pub const primary_key = pk;
    };
}
