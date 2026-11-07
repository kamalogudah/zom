//! Changesets = ROM's `ROM::Changeset`.
//!
//! A changeset holds the data for one write plus the relation it targets,
//! and only touches the dataset on `commit`. `Create.map` plays the role of
//! ROM's `map { ... }` transformation pipeline, and `associate` ROM's
//! `changeset.associate(user)`.
//!
//! `Relation.create`, `createMany` and `update` check the adapter's capabilities;
//! `commit` checks them again for a changeset built by hand.
//!
//! ## Associated creates
//!
//! ROM writes `posts.changeset(:create, data).associate(user)`, where `data`
//! leaves out `user_id`. A Zig struct has no "unset" fields: every field
//! without a default needs a value, so a `PostTuple` literal without
//! `user_id` doesn't compile. The ways around it, and what zom does:
//!
//! - A default for the foreign key in the tuple (`user_id: u32 = 0`) changes
//!   the schema for every caller, and a post created without `associate`
//!   silently belongs to user 0. zom doesn't ask for this.
//! - `create(data: anytype)` taking a partial struct would match ROM's
//!   order, and could even track the unset fields in the changeset's type.
//!   But Zig doesn't coerce an anonymous struct value to a named
//!   struct, so the literal would lose its result type: `.id = @intCast(n)`
//!   or `.at = .now()` stop compiling, and a type error is reported inside
//!   zom instead of at the literal. That is too high a price on every
//!   `create`, so `create` keeps taking a `Tuple`.
//! - The parent comes first: `posts.associate(.author, user)` returns a
//!   `Scoped` changeset builder whose `create` takes `Input`, the tuple
//!   without `user_id` (the same fields, types and defaults otherwise). The
//!   literal keeps its result type, and the key can be neither forgotten nor
//!   given twice, because it is not a field. This is the form to use.
//!
//!       const author = (try users.byPk(1).one(a)).?;
//!       _ = try posts.associate(.author, author)
//!           .create(.{ .id = 13, .title = "...", .published = true })
//!           .commit();
//!
//! ROM's order works too, with the key given any value first:
//! `posts.create(.{ .user_id = undefined, ... }).associate(.author, author)`.
//! `associate` overwrites it, but nothing catches a forgotten `associate`.
//!
//! For batches, `posts.associate(.author, user).createMany(rows)` takes
//! `[]const Input`, and `posts.createMany(rows).associate(.author, user)`
//! takes whole tuples. Both build the stored tuples in a copy, since the
//! rows are borrowed and const, so they commit with `commitAlloc(allocator)`
//! (plain `commit` is a compile error there).
//!
//! ## Plugins
//!
//! `Create.commit` and `Update.commit` run the schema's plugin hooks
//! (`beforeCreate`, `beforeUpdate`; see plugins.zig) just before the
//! dataset call. A batch whose schema has a `beforeCreate` hook runs it on
//! a copy of the borrowed rows, so it commits with `commitAlloc` too.

const std = @import("std");
const q = @import("query.zig");
const Association = @import("schema.zig").Association;
const plugins = @import("plugins.zig");

const EnumLiteral = @TypeOf(.enum_literal);

/// A set of a relation's tuple fields, as a struct of bools: the foreign
/// keys an `associate` has set.
pub fn FieldSet(comptime Rel: type) type {
    return std.enums.EnumFieldStruct(Rel.Field, bool, false);
}

pub fn Create(comptime Rel: type) type {
    return struct {
        const Self = @This();

        relation: Rel,
        tuple: Rel.Tuple,

        /// Pure transformation step, applied in order before commit.
        pub fn map(self: Self, comptime f: fn (Rel.Tuple) Rel.Tuple) Self {
            var next = self;
            next.tuple = f(self.tuple);
            return next;
        }

        /// ROM's `changeset.associate(user)`: sets the tuple's foreign key of
        /// the `belongsTo` association `assoc` to `parent`'s key, replacing
        /// whatever it held. See `checkAssociate` for what `parent` may be.
        /// Prefer `relation.associate(assoc, parent).create(...)`, whose
        /// input has no foreign key to forget (see the top of this file).
        pub fn associate(self: Self, comptime assoc: EnumLiteral, parent: anytype) Self {
            const a = comptime checkAssociate(Rel, assoc, @TypeOf(parent));
            var next = self;
            @field(next.tuple, a.foreign_key) = @field(parent, a.primary_key);
            return next;
        }

        /// Returns the tuple as stored by the adapter. On an adapter whose
        /// strings are caller-owned (zom-pg) the returned strings need an
        /// allocator, so use `commitAlloc` there.
        pub fn commit(self: Self) !Rel.Tuple {
            comptime Rel.Adapter.require(Rel.schema, .writable, "create");
            if (comptime Rel.Adapter.insertTakesAllocator(Rel.schema))
                @compileError("zom: adapter '" ++ Rel.Adapter.name ++ "' returns the stored tuple of relation '" ++
                    Rel.schema.name ++ "' with strings in an allocator; use `commitAlloc(allocator)` and free " ++
                    "the result with the relation's `freeOne(allocator, tuple)`");
            const tuple = try self.prepared();
            const span = self.relation.instrument(.insert, null);
            return span.end(self.relation.dataset.insert(tuple));
        }

        /// The tuple after the schema's `beforeCreate` hooks.
        inline fn prepared(self: Self) !Rel.Tuple {
            if (comptime !plugins.hasHook(Rel.schema, "beforeCreate")) return self.tuple;
            var t = self.tuple;
            try plugins.beforeCreate(Rel.schema, &t, &self.relation.plugin_context);
            return t;
        }

        /// `commit` on any adapter: the returned tuple's strings are
        /// allocated with `allocator` when the adapter's strings are
        /// caller-owned. Free it with the relation's `freeOne(allocator,
        /// tuple)`, which is a no-op elsewhere.
        pub fn commitAlloc(self: Self, allocator: std.mem.Allocator) !Rel.Tuple {
            comptime Rel.Adapter.require(Rel.schema, .writable, "create");
            const tuple = try self.prepared();
            const span = self.relation.instrument(.insert, null);
            if (comptime Rel.Adapter.insertTakesAllocator(Rel.schema))
                return span.end(self.relation.dataset.insert(tuple, allocator));
            return span.end(self.relation.dataset.insert(tuple));
        }
    };
}

/// Inserts every tuple in `tuples`, which the changeset borrows: the slice
/// must stay alive until `commit`.
///
/// With `insertMany` (`.batch_insert`) the adapter decides what a failure
/// leaves behind; the memory adapter inserts all or nothing. Without it,
/// `commit` falls back to calling `insert` once per tuple, in order, and
/// stops at the first error: the tuples before the failing one are already
/// stored and stay stored, and the count is lost with the error. Use a
/// transaction, or an adapter with `insertMany`, when that matters.
pub fn CreateMany(comptime Rel: type) type {
    return CreateManyOf(Rel, Rel.Tuple, .{});
}

/// A batch insert of `Row`s: whole tuples, or `Scoped(Rel, keys).Input`
/// rows. The fields in `keys` are taken from `patch`, in a copy of every
/// row made at commit, so the changeset commits with `commitAlloc` once
/// `keys` is not empty.
pub fn CreateManyOf(comptime Rel: type, comptime Row: type, comptime keys: FieldSet(Rel)) type {
    return struct {
        const Self = @This();
        const has_keys = !isEmpty(Rel, keys);
        const has_hooks = plugins.hasHook(Rel.schema, "beforeCreate");
        const needs_copy = has_keys or has_hooks;

        relation: Rel,
        tuples: []const Row,
        /// The values of the fields in `keys`; the rest is unused.
        patch: Rel.Tuple = undefined,

        /// Like `Create.associate`, for every tuple of the batch. The rows
        /// are borrowed and const, so the key is set on a copy, and the
        /// changeset commits with `commitAlloc(allocator)`.
        pub fn associate(self: Self, comptime assoc: EnumLiteral, parent: anytype) CreateManyOf(Rel, Row, withKey(Rel, keys, assoc, @TypeOf(parent))) {
            const a = comptime checkAssociate(Rel, assoc, @TypeOf(parent));
            if (comptime Row != Rel.Tuple and !@hasField(Row, a.foreign_key))
                @compileError("zom: `associate(." ++ a.name ++ ", ...)` on relation '" ++ Rel.schema.name ++
                    "': '" ++ a.foreign_key ++ "' was already set by an earlier `associate`");
            var patch = self.patch;
            @field(patch, a.foreign_key) = @field(parent, a.primary_key);
            return .{ .relation = self.relation, .tuples = self.tuples, .patch = patch };
        }

        /// Returns the number of tuples inserted.
        pub fn commit(self: Self) !usize {
            if (has_keys)
                @compileError("zom: `createMany` on relation '" ++ Rel.schema.name ++ "' after `associate` sets the " ++
                    "foreign key on a copy of the borrowed rows; commit it with `commitAlloc(allocator)`");
            if (has_hooks)
                @compileError("zom: `createMany` on relation '" ++ Rel.schema.name ++ "' runs its schema's `beforeCreate` " ++
                    "plugin hooks on a copy of the borrowed rows; commit it with `commitAlloc(allocator)`");
            return insertAll(Rel, self.relation, self.tuples);
        }

        /// `commit` for any batch: after `associate`, or with `beforeCreate`
        /// plugin hooks, builds the stored tuples in a copy allocated with
        /// `allocator`, freed before returning. Otherwise it allocates
        /// nothing.
        pub fn commitAlloc(self: Self, allocator: std.mem.Allocator) !usize {
            if (!needs_copy) return insertAll(Rel, self.relation, self.tuples);
            comptime requireBatch(Rel);
            if (self.tuples.len == 0) return 0;
            const rows = try allocator.alloc(Rel.Tuple, self.tuples.len);
            defer allocator.free(rows);
            for (rows, self.tuples) |*row, in| {
                row.* = merge(Rel, keys, in, self.patch);
                if (has_hooks) try plugins.beforeCreate(Rel.schema, row, &self.relation.plugin_context);
            }
            return insertAll(Rel, self.relation, rows);
        }
    };
}

/// What `relation.associate(.assoc, parent)` returns: a builder for creates
/// whose foreign keys in `keys` come from parents, so `Input`, the struct
/// `create` and `createMany` take, leaves them out. Chain `associate` to
/// set the keys of several associations.
pub fn Scoped(comptime Rel: type, comptime keys: FieldSet(Rel)) type {
    return struct {
        const Self = @This();

        /// `Rel.Tuple` without the fields in `keys`, with the same types,
        /// defaults and order otherwise.
        pub const Input = Without(Rel, keys);

        relation: Rel,
        /// The values of the fields in `keys`; the rest is unused.
        patch: Rel.Tuple = undefined,

        /// Sets another association's foreign key, which `Input` then
        /// leaves out too. Setting the same one twice is a compile error.
        pub fn associate(self: Self, comptime assoc: EnumLiteral, parent: anytype) Scoped(Rel, withKey(Rel, keys, assoc, @TypeOf(parent))) {
            const a = comptime checkAssociate(Rel, assoc, @TypeOf(parent));
            if (comptime @field(keys, a.foreign_key))
                @compileError("zom: `associate(." ++ a.name ++ ", ...)` on relation '" ++ Rel.schema.name ++
                    "': '" ++ a.foreign_key ++ "' was already set by an earlier `associate`");
            var patch = self.patch;
            @field(patch, a.foreign_key) = @field(parent, a.primary_key);
            return .{ .relation = self.relation, .patch = patch };
        }

        /// `relation.create` with the foreign keys filled in.
        pub fn create(self: Self, data: Input) Create(Rel) {
            comptime Rel.Adapter.require(Rel.schema, .writable, "create");
            return .{ .relation = self.relation, .tuple = merge(Rel, keys, data, self.patch) };
        }

        /// `relation.createMany` with the foreign keys filled in, on a copy
        /// of `rows` (borrowed until commit): commit it with
        /// `commitAlloc(allocator)`.
        pub fn createMany(self: Self, rows: []const Input) CreateManyOf(Rel, Input, keys) {
            comptime requireBatch(Rel);
            return .{ .relation = self.relation, .tuples = rows, .patch = self.patch };
        }
    };
}

/// `keys` plus the foreign key of association `assoc`, once `P` is known to
/// be a parent for it.
pub fn withKey(comptime Rel: type, comptime keys: FieldSet(Rel), comptime assoc: EnumLiteral, comptime P: type) FieldSet(Rel) {
    const a = checkAssociate(Rel, assoc, P);
    var next = keys;
    @field(next, a.foreign_key) = true;
    return next;
}

/// The `belongsTo` association `assoc` of `Rel`'s schema, once `P` is known
/// to be a parent it can take the key from: the target's tuple, or a struct
/// whose every field is a field of it with the same type, including the
/// key, such as a `select` of it. Anything else is a compile error, and so
/// is a `hasMany` association, whose foreign key is in the other schema's
/// rows.
pub fn checkAssociate(comptime Rel: type, comptime assoc: EnumLiteral, comptime P: type) Association {
    const S = Rel.schema;
    const a = S.association(assoc);
    const where = "zom: `associate(." ++ a.name ++ ", ...)` on relation '" ++ S.name ++ "'";
    if (a.kind == .custom)
        @compileError(where ++ ": '" ++ a.name ++ "' is a custom association, which has no foreign key to set");
    if (a.kind == .has_many) {
        var other: []const u8 = "";
        for (a.target.association_names) |n| {
            const b = @field(a.target.associations, n);
            if (b.kind == .belongs_to and b.target == S and std.mem.eql(u8, b.foreign_key, a.foreign_key))
                other = ", e.g. `" ++ a.target.name ++ ".associate(." ++ n ++ ", " ++ S.name ++ "_row)`";
        }
        @compileError(where ++ ": '" ++ a.name ++ "' is a hasMany, so its foreign key '" ++ a.foreign_key ++
            "' is in the rows of \"" ++ a.target.name ++ "\", not in this tuple; associate from that side, through a belongsTo" ++ other);
    }
    const Target = a.target.Tuple;
    if (P == Target) return a;
    const fits = blk: {
        if (@typeInfo(P) != .@"struct" or !@hasField(P, a.primary_key)) break :blk false;
        const info = @typeInfo(P).@"struct";
        for (info.field_names, info.field_types) |name, F| {
            if (!@hasField(Target, name) or @FieldType(Target, name) != F) break :blk false;
        }
        break :blk true;
    };
    if (!fits)
        @compileError(where ++ ": the parent must be a " ++ @typeName(Target) ++ " (the tuple of \"" ++ a.target.name ++
            "\"), or a `select` of it that kept '" ++ a.primary_key ++ "', found `" ++ @typeName(P) ++ "`");
    return a;
}

/// `Rel.Tuple` without the fields in `keys`.
fn Without(comptime Rel: type, comptime keys: FieldSet(Rel)) type {
    const info = @typeInfo(Rel.Tuple).@"struct";
    var n: usize = 0;
    for (info.field_names) |name| {
        if (!@field(keys, name)) n += 1;
    }
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    var attrs: [n]std.lang.Type.Struct.FieldAttributes = undefined;
    var i: usize = 0;
    for (info.field_names, info.field_types, info.field_attrs) |name, F, field_attrs| {
        if (@field(keys, name)) continue;
        names[i] = name;
        types[i] = F;
        attrs[i] = field_attrs;
        i += 1;
    }
    const names_final = names;
    const types_final = types;
    const attrs_final = attrs;
    return @Struct(.auto, null, &names_final, &types_final, &attrs_final);
}

/// The tuple with the fields in `keys` from `patch` and the rest from `in`.
fn merge(comptime Rel: type, comptime keys: FieldSet(Rel), in: anytype, patch: Rel.Tuple) Rel.Tuple {
    if (@TypeOf(in) == Rel.Tuple) {
        var t = in;
        inline for (@typeInfo(Rel.Tuple).@"struct".field_names) |name| {
            if (comptime @field(keys, name)) @field(t, name) = @field(patch, name);
        }
        return t;
    }
    var t: Rel.Tuple = undefined;
    inline for (@typeInfo(Rel.Tuple).@"struct".field_names) |name| {
        @field(t, name) = if (comptime @field(keys, name)) @field(patch, name) else @field(in, name);
    }
    return t;
}

fn isEmpty(comptime Rel: type, comptime keys: FieldSet(Rel)) bool {
    for (@typeInfo(Rel.Tuple).@"struct".field_names) |name| {
        if (@field(keys, name)) return false;
    }
    return true;
}

fn requireBatch(comptime Rel: type) void {
    Rel.Adapter.requireAny(Rel.schema, &.{ .batch_insert, .writable }, "createMany");
}

fn insertAll(comptime Rel: type, relation: Rel, tuples: []const Rel.Tuple) !usize {
    comptime requireBatch(Rel);
    if (tuples.len == 0) return 0;
    if (comptime Rel.Adapter.has(Rel.schema, .batch_insert)) {
        const span = relation.instrument(.insert_many, null);
        return span.end(relation.dataset.insertMany(tuples));
    }
    if (comptime Rel.Adapter.insertTakesAllocator(Rel.schema))
        @compileError("zom: `createMany` on relation '" ++ Rel.schema.name ++ "' would loop over adapter '" ++
            Rel.Adapter.name ++ "'s `insert`, which allocates the tuple it returns; the dataset needs `insertMany`");
    for (tuples) |t| {
        const span = relation.instrument(.insert, null);
        _ = try span.end(relation.dataset.insert(t));
    }
    return tuples.len;
}

pub fn Update(comptime Rel: type) type {
    return struct {
        const Self = @This();
        /// Includes the changes plugins add at commit.
        pub const max_changes = plugins.max_changes;

        relation: Rel,
        changes: [max_changes]Rel.Q.Change = undefined,
        change_count: usize = 0,

        pub fn set(self: Self, comptime field: Rel.Field, value: anytype) Self {
            const F = @FieldType(Rel.Tuple, @tagName(field));
            comptime q.assertSettable(F, @TypeOf(value), @tagName(field));
            if (comptime q.isComptimeOnly(@TypeOf(value))) comptime q.assertLiteral(F, value, @tagName(field));
            std.debug.assert(self.change_count < max_changes);
            var next = self;
            next.changes[next.change_count] = .{ .field = field, .value = q.toValue(value) };
            next.change_count += 1;
            return next;
        }

        /// Returns the number of tuples updated. Runs the schema's
        /// `beforeUpdate` plugin hooks first, unless there are no changes.
        pub fn commit(self: Self) !usize {
            comptime Rel.Adapter.require(Rel.schema, .updatable, "update");
            if (self.change_count == 0) return 0;
            const query = try self.relation.writeQuery();
            if (comptime !plugins.hasHook(Rel.schema, "beforeUpdate")) {
                const span = self.relation.instrument(.update, &query);
                return span.end(self.relation.dataset.update(query, self.changes[0..self.change_count]));
            }
            var list: plugins.ChangeList(Rel.Tuple) = .{ .items = self.changes, .len = self.change_count };
            try plugins.beforeUpdate(Rel.schema, &list, &self.relation.plugin_context);
            const span = self.relation.instrument(.update, &query);
            return span.end(self.relation.dataset.update(query, list.slice()));
        }
    };
}
