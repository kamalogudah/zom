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
//!
//! ## Views: no primary key
//!
//! `pk` may be `null` for a dataset whose rows have no single unique field,
//! such as a read-only view (TigerBeetle's balance history, where a row is
//! unique per account and timestamp but neither field is unique alone):
//!
//!     const BalanceSchema = zom.Schema(Balance, "account_balances", null, .{
//!         .associations = struct {
//!             pub const account = zom.belongsTo(AccountSchema, .account_id);
//!         },
//!     });
//!
//! `has_primary_key` is then false, and whatever needs the key is a compile
//! error: `byPk`, `S.primary_key` itself, a `belongsTo` pointing at the view
//! and a `hasMany` or custom association declared on it. A `belongsTo` from
//! the view and a `hasMany` into it (keyed by the other schema's key) work.
//! The memory store skips its primary-key checks for it.

const std = @import("std");
const plugins_mod = @import("plugins.zig");

const EnumLiteral = @TypeOf(.enum_literal);

pub const AssociationKind = enum {
    /// The target's rows hold the foreign key: a user has many posts,
    /// `posts.user_id` -> `users.id`.
    has_many,
    /// The source's rows hold the foreign key: a post belongs to a user,
    /// `posts.user_id` -> `users.id`.
    belongs_to,
    /// No foreign key zom can see: the target's dataset finds the rows for
    /// each source key itself, through its `loadAssociation` (see
    /// combine.zig). A TigerBeetle transfer belongs to an account as its
    /// `debit_account_id` *or* its `credit_account_id`, which neither of
    /// the other kinds can say. Declared with `zom.customAssociation`.
    custom,
};

/// How many target rows each source row has: a slice in the combined
/// entity for `.many`, an optional for `.one`. `hasMany` is `.many` and
/// `belongsTo` `.one`; a custom association says which.
pub const Cardinality = enum { many, one };

/// What `zom.hasMany` and `zom.belongsTo` return: an association as written,
/// before the schema declaring it fills in its own side. Comptime only (it
/// holds a type).
pub const AssociationDef = struct {
    kind: AssociationKind,
    target: type,
    /// Empty for `.custom`.
    foreign_key: []const u8,
    cardinality: Cardinality,
    /// `.custom` only: the name the target's dataset knows it by.
    tag: []const u8 = "",
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
///
/// A `.custom` association has no `foreign_key` (it is empty), and its
/// `primary_key` is the source's: the key handed to the target dataset's
/// `loadAssociation`. `tag` is what that dataset knows it by.
pub const Association = struct {
    name: []const u8,
    kind: AssociationKind,
    source: type,
    target: type,
    foreign_key: []const u8,
    primary_key: []const u8,
    cardinality: Cardinality = .many,
    tag: []const u8 = "",

    /// The schema whose tuple holds `foreign_key`. None for `.custom`.
    pub fn Child(comptime a: Association) type {
        return switch (a.kind) {
            .has_many => a.target,
            .belongs_to => a.source,
            .custom => @compileError("zom: custom association '" ++ a.name ++ "' has no foreign key, so no child schema"),
        };
    }

    /// The schema whose tuple holds `primary_key`.
    pub fn Parent(comptime a: Association) type {
        return if (a.kind == .belongs_to) a.target else a.source;
    }

    /// The type of the keys a combine groups by: `primary_key`'s type in
    /// the parent's tuple, without `?`. `loadAssociation` takes a slice of
    /// them.
    pub fn Key(comptime a: Association) type {
        const K = @FieldType(a.Parent().Tuple, a.primary_key);
        return switch (@typeInfo(K)) {
            .optional => |o| o.child,
            else => K,
        };
    }
};

/// `Target`'s rows hold `foreign_key`, pointing at this schema's primary
/// key: `.posts = zom.hasMany(PostSchema, .user_id)` on the users schema.
pub fn hasMany(comptime Target: type, comptime foreign_key: EnumLiteral) AssociationDef {
    checkTarget("zom.hasMany", Target);
    return .{ .kind = .has_many, .target = Target, .foreign_key = @tagName(foreign_key), .cardinality = .many };
}

/// This schema's rows hold `foreign_key`, pointing at `Target`'s primary
/// key: `.author = zom.belongsTo(UserSchema, .user_id)` on the posts schema.
/// The foreign key may be optional (`?u32` for a `u32` key) for a row that
/// belongs to nothing.
pub fn belongsTo(comptime Target: type, comptime foreign_key: EnumLiteral) AssociationDef {
    checkTarget("zom.belongsTo", Target);
    return .{ .kind = .belongs_to, .target = Target, .foreign_key = @tagName(foreign_key), .cardinality = .one };
}

/// An association whose rows `Target`'s dataset finds itself: `combine`
/// hands it the source rows' primary keys and it returns each key's rows,
/// through its `loadAssociation` (see combine.zig). `tag` names the
/// association to that dataset; `cardinality` says whether each source row
/// has a slice (`.many`) or an optional (`.one`) of them. zom-tigerbeetle's
/// `Account` declares
/// `.transfers = zom.customAssociation(Transfer, .account_transfers, .many)`.
/// A custom association can't be joined or associated, and combining it
/// needs a target dataset that declares `loadAssociation`.
pub fn customAssociation(comptime Target: type, comptime tag: EnumLiteral, comptime cardinality: Cardinality) AssociationDef {
    checkTarget("zom.customAssociation", Target);
    return .{ .kind = .custom, .target = Target, .foreign_key = "", .cardinality = cardinality, .tag = @tagName(tag) };
}

/// `zom.Schema(T, name, pk, .{})`, or with associations:
/// `pk` is a field of `T` (`.id`), or `null` for a view without one (see
/// the file comment).
/// `zom.Schema(T, name, pk, .{ .associations = struct { pub const posts = zom.hasMany(PostSchema, .user_id); } })`.
/// See the file comment for the two forms `associations` takes. The other
/// option, `.plugins = .{ zom.plugins.timestamps(.{}) }`, is described in
/// plugins.zig.
pub fn Schema(
    comptime T: type,
    comptime dataset_name: []const u8,
    comptime pk: ?std.meta.FieldEnum(T),
    comptime options: anytype,
) type {
    if (@typeInfo(T) != .@"struct")
        @compileError("zom.Schema: tuple type must be a struct, got " ++ @typeName(T));
    const label = "zom.Schema(\"" ++ dataset_name ++ "\")";
    const O = @TypeOf(options);
    if (@typeInfo(O) != .@"struct")
        @compileError(label ++ ": options must be a struct literal such as .{} or .{ .associations = ... }, found `" ++ @typeName(O) ++ "`");
    for (@typeInfo(O).@"struct".field_names) |option| {
        if (!std.mem.eql(u8, option, "associations") and !std.mem.eql(u8, option, "plugins"))
            @compileError(label ++ ": unknown option '" ++ option ++ "' (options: associations, plugins)");
    }
    const defs = if (@hasField(O, "associations")) options.associations else struct {};
    const plugin_list = if (@hasField(O, "plugins")) plugins_mod.checkList(dataset_name, options.plugins) else .{};

    return struct {
        const Self = @This();

        pub const Tuple = T;
        pub const name = dataset_name;
        /// False for a view (`pk` given as `null`).
        pub const has_primary_key = pk != null;

        /// The primary key; a compile error to use on a view.
        pub const primary_key: std.meta.FieldEnum(T) = pk orelse
            @compileError(label ++ " has no primary key (it was declared with `null`, as a view), " ++
                "so nothing that needs one (such as `byPk`) can be used on it; filter with `where` instead");

        /// Lets `zom.hasMany` / `zom.belongsTo` (and anything else) tell a
        /// schema type from any other type.
        pub const is_zom_schema = true;

        /// The plugin types from `.plugins`, in order; `.{}` without any.
        /// See plugins.zig.
        pub const plugins = plugin_list;

        /// The names of the associations, in declaration order.
        pub const association_names: []const []const u8 = associationNames(defs);

        /// One `zom.Association` field per association:
        /// `S.associations.posts.target`. Iterate it with
        /// `inline for (S.association_names)` and `S.association`.
        pub const associations = blk: {
            const n = association_names.len;
            var types: [n]type = @splat(Association);
            var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;
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
            const Target = def.target;
            const kind_name = switch (def.kind) {
                .has_many => "zom.hasMany",
                .belongs_to => "zom.belongsTo",
                .custom => "zom.customAssociation",
            };
            const where = kind_name ++ ": association '" ++ assoc ++ "' of schema \"" ++ dataset_name ++ "\"";
            if (def.kind == .belongs_to and !Target.has_primary_key)
                @compileError(where ++ ": the target, schema \"" ++ Target.name ++
                    "\", has no primary key (it is a view), so nothing can belong to it");
            if (def.kind != .belongs_to and pk == null)
                @compileError(where ++ ": this schema has no primary key (it is a view), so it has no key " ++
                    "for the target's rows to point at; declare the association on the other side instead");
            if (def.kind == .custom) return .{
                .name = assoc,
                .kind = .custom,
                .source = Self,
                .target = Target,
                .foreign_key = "",
                .primary_key = @tagName(pk.?),
                .cardinality = def.cardinality,
                .tag = def.tag,
            };
            const Child, const Parent, const parent_pk = switch (def.kind) {
                .has_many => .{ Target.Tuple, T, @tagName(pk.?) },
                .belongs_to => .{ T, Target.Tuple, @tagName(Target.primary_key) },
                .custom => unreachable,
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
                .cardinality = def.cardinality,
            };
        }

        // Check every association when the schema type is analysed, so a bad
        // one fails even if nothing uses it yet. This runs after `Self` and
        // the schemas it names exist, so mutual references are fine here.
        comptime {
            for (association_names) |a| _ = resolve(a);
            plugins_mod.validate(Self);
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
        for (@typeInfo(D).@"struct".decl_names) |d| names = names ++ .{d};
    } else {
        for (@typeInfo(D).@"struct".field_names) |f| names = names ++ .{f};
    }
    for (names) |n| {
        const V = @TypeOf(@field(defs, n));
        if (V != AssociationDef)
            @compileError("zom.Schema: association '" ++ n ++ "' must be zom.hasMany(...), zom.belongsTo(...) or zom.customAssociation(...), found `" ++
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
    for (@typeInfo(T).@"struct".field_names, 0..) |f, i| out = out ++ (if (i == 0) "" else ", ") ++ f;
    return out;
}

fn list(comptime items: []const []const u8, comptime empty: []const u8) []const u8 {
    if (items.len == 0) return empty;
    var out: []const u8 = "";
    for (items, 0..) |item, i| out = out ++ (if (i == 0) "" else ", ") ++ item;
    return out;
}
