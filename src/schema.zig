//! Schema = ROM's `schema(:users) do ... end`.
//!
//! The tuple struct is the attribute list; Zig's type system already gives
//! us types, optionality (`?T`) and defaults, so the schema only adds the
//! dataset name, the primary key and the associations:
//!
//!     const UserSchema = zom.Schema(User, "users", .id, .{
//!         .associations = struct {
//!             pub const posts = zom.hasMany(PostSchema, .user_id);
//!         },
//!     });
//!     const PostSchema = zom.Schema(Post, "posts", .id, .{
//!         .associations = struct {
//!             pub const author = zom.belongsTo(UserSchema, .user_id);
//!         },
//!     });
//!
//! ## Why `struct { pub const ... }` and not `.{ .posts = ... }`
//!
//! Both forms are accepted. The anonymous-struct form,
//! `.associations = .{ .posts = zom.hasMany(PostSchema, .user_id) }`, is an
//! argument to `Schema`, and Zig evaluates arguments before the call. So
//! `UserSchema`'s value needs `PostSchema`'s value. If `PostSchema` also
//! names `UserSchema`, that is a "dependency loop" error. Storing the target
//! and only looking at it later doesn't help, because the loop is in
//! computing the two declarations, before anything inspects them.
//!
//! A container's declarations are analysed only when something uses them.
//! Passing `struct { pub const posts = ... }` gives `Schema` a type whose
//! `posts` hasn't been evaluated yet. Both schema declarations finish first,
//! and the associations are evaluated afterwards, when both types exist.
//! Use the anonymous-struct form only when no association points back
//! (directly or through other schemas) at the schema declaring it.

const std = @import("std");

const EnumLiteral = @TypeOf(.enum_literal);

pub const AssociationKind = enum {
    /// The target's rows hold the foreign key: a user has many posts,
    /// `posts.user_id` -> `users.id`.
    has_many,
    /// The source's rows hold the foreign key: a post belongs to a user,
    /// `posts.user_id` -> `users.id`.
    belongs_to,
};

/// What `zom.hasMany` and `zom.belongsTo` return: an association as written,
/// before the schema declaring it fills in its own side. Comptime only (it
/// holds a type).
pub const AssociationDef = struct {
    kind: AssociationKind,
    target: type,
    foreign_key: []const u8,
};

/// An association resolved by the schema that declares it, as returned by
/// `S.association(.name)` and held in `S.associations`. Comptime only.
///
/// Field names are strings, ready for `@field(row, a.foreign_key)`.
///
/// `foreign_key` is a field of the target's tuple for `.has_many` and of the
/// source's tuple for `.belongs_to`. `primary_key` is the field it points
/// at: the source's primary key for `.has_many`, the target's for
/// `.belongs_to`.
pub const Association = struct {
    name: []const u8,
    kind: AssociationKind,
    source: type,
    target: type,
    foreign_key: []const u8,
    primary_key: []const u8,

    /// The schema whose tuple holds `foreign_key`.
    pub fn Child(comptime a: Association) type {
        return if (a.kind == .has_many) a.target else a.source;
    }

    /// The schema whose tuple holds `primary_key`.
    pub fn Parent(comptime a: Association) type {
        return if (a.kind == .has_many) a.source else a.target;
    }
};

/// `Target`'s rows hold `foreign_key`, pointing at this schema's primary
/// key: `.posts = zom.hasMany(PostSchema, .user_id)` on the users schema.
pub fn hasMany(comptime Target: type, comptime foreign_key: EnumLiteral) AssociationDef {
    checkTarget("zom.hasMany", Target);
    return .{ .kind = .has_many, .target = Target, .foreign_key = @tagName(foreign_key) };
}

/// This schema's rows hold `foreign_key`, pointing at `Target`'s primary
/// key: `.author = zom.belongsTo(UserSchema, .user_id)` on the posts schema.
/// The foreign key may be optional (`?u32` for a `u32` key) for a row that
/// belongs to nothing.
pub fn belongsTo(comptime Target: type, comptime foreign_key: EnumLiteral) AssociationDef {
    checkTarget("zom.belongsTo", Target);
    return .{ .kind = .belongs_to, .target = Target, .foreign_key = @tagName(foreign_key) };
}

/// `zom.Schema(T, name, pk, .{})`, or with associations:
/// `zom.Schema(T, name, pk, .{ .associations = struct { pub const posts = zom.hasMany(PostSchema, .user_id); } })`.
/// See the file comment for the two forms `associations` takes.
pub fn Schema(
    comptime T: type,
    comptime dataset_name: []const u8,
    comptime pk: std.meta.FieldEnum(T),
    comptime options: anytype,
) type {
    if (@typeInfo(T) != .@"struct")
        @compileError("zom.Schema: tuple type must be a struct, got " ++ @typeName(T));
    const label = "zom.Schema(\"" ++ dataset_name ++ "\")";
    const O = @TypeOf(options);
    if (@typeInfo(O) != .@"struct")
        @compileError(label ++ ": options must be a struct literal such as .{} or .{ .associations = ... }, found `" ++ @typeName(O) ++ "`");
    for (@typeInfo(O).@"struct".fields) |f| {
        if (!std.mem.eql(u8, f.name, "associations"))
            @compileError(label ++ ": unknown option '" ++ f.name ++ "' (options: associations)");
    }
    const defs = if (@hasField(O, "associations")) options.associations else struct {};

    return struct {
        const Self = @This();

        pub const Tuple = T;
        pub const name = dataset_name;
        pub const primary_key = pk;

        /// Lets `zom.hasMany` / `zom.belongsTo` (and anything else) tell a
        /// schema type from any other type.
        pub const is_zom_schema = true;

        /// The names of the associations, in declaration order.
        pub const association_names: []const []const u8 = associationNames(defs);

        /// One `zom.Association` field per association:
        /// `S.associations.posts.target`. Iterate it with
        /// `inline for (S.association_names)` and `S.association`.
        pub const associations = blk: {
            const n = association_names.len;
            var types: [n]type = @splat(Association);
            var attrs: [n]std.builtin.Type.StructField.Attributes = undefined;
            for (association_names, 0..) |a, i| attrs[i] = .{
                .@"comptime" = true,
                .default_value_ptr = &resolve(a),
            };
            const Associations = @Struct(.auto, null, association_names, &types, &attrs);
            break :blk Associations{};
        };

        /// The association named `assoc`, or a compile error listing the
        /// ones this schema has.
        pub fn association(comptime assoc: EnumLiteral) Association {
            return comptime find(@tagName(assoc));
        }

        fn find(comptime wanted: []const u8) Association {
            for (association_names) |a| {
                if (std.mem.eql(u8, a, wanted)) return resolve(a);
            }
            @compileError("zom.association: '" ++ wanted ++ "' is not an association of schema \"" ++
                dataset_name ++ "\" (associations: " ++ list(association_names, "none") ++ ")");
        }

        fn resolve(comptime assoc: []const u8) Association {
            const def = @field(defs, assoc);
            const where = (if (def.kind == .has_many) "zom.hasMany" else "zom.belongsTo") ++
                ": association '" ++ assoc ++ "' of schema \"" ++ dataset_name ++ "\"";
            const Target = def.target;
            const Child, const Parent, const parent_pk = switch (def.kind) {
                .has_many => .{ Target.Tuple, T, @tagName(pk) },
                .belongs_to => .{ T, Target.Tuple, @tagName(Target.primary_key) },
            };
            const fk = def.foreign_key;
            if (!@hasField(Child, fk))
                @compileError(where ++ ": foreign key '" ++ fk ++ "' is not a field of " ++ @typeName(Child) ++
                    " (fields: " ++ fieldList(Child) ++ ")");
            const Fk = @FieldType(Child, fk);
            const Pk = @FieldType(Parent, parent_pk);
            if (Fk != Pk and Fk != ?Pk)
                @compileError(where ++ ": foreign key " ++ @typeName(Child) ++ "." ++ fk ++ " is `" ++ @typeName(Fk) ++
                    "`, but the key it points at, " ++ @typeName(Parent) ++ "." ++ parent_pk ++ ", is `" ++
                    @typeName(Pk) ++ "` (expected `" ++ @typeName(Pk) ++ "` or `?" ++ @typeName(Pk) ++ "`)");
            return .{
                .name = assoc,
                .kind = def.kind,
                .source = Self,
                .target = Target,
                .foreign_key = def.foreign_key,
                .primary_key = parent_pk,
            };
        }

        // Check every association when the schema type is analysed, so a bad
        // one fails even if nothing uses it yet. This runs after `Self` and
        // the schemas it names exist, so mutual references are fine here.
        comptime {
            for (association_names) |a| _ = resolve(a);
        }
    };
}

fn associationNames(comptime defs: anytype) []const []const u8 {
    const lazy = @TypeOf(defs) == type;
    const D = if (lazy) defs else @TypeOf(defs);
    if (@typeInfo(D) != .@"struct")
        @compileError("zom.Schema: associations must be `struct { pub const name = zom.hasMany(...); }` or `.{ .name = zom.hasMany(...) }`, found `" ++
            @typeName(D) ++ "`");
    var names: []const []const u8 = &.{};
    if (lazy) {
        for (@typeInfo(D).@"struct".decls) |d| names = names ++ .{d.name};
    } else {
        for (@typeInfo(D).@"struct".fields) |f| names = names ++ .{f.name};
    }
    for (names) |n| {
        const V = @TypeOf(@field(defs, n));
        if (V != AssociationDef)
            @compileError("zom.Schema: association '" ++ n ++ "' must be zom.hasMany(...) or zom.belongsTo(...), found `" ++
                @typeName(V) ++ "`");
    }
    return names;
}

fn checkTarget(comptime func: []const u8, comptime Target: type) void {
    if (!isSchema(Target))
        @compileError(func ++ ": the target must be a zom.Schema type, found `" ++ @typeName(Target) ++ "`");
}

fn isSchema(comptime S: type) bool {
    return switch (@typeInfo(S)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(S, "is_zom_schema"),
        else => false,
    };
}

fn fieldList(comptime T: type) []const u8 {
    var out: []const u8 = "";
    for (@typeInfo(T).@"struct".fields, 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ f.name;
    return out;
}

fn list(comptime items: []const []const u8, comptime empty: []const u8) []const u8 {
    if (items.len == 0) return empty;
    var out: []const u8 = "";
    for (items, 0..) |item, i| out = out ++ (if (i == 0) "" else ", ") ++ item;
    return out;
}
