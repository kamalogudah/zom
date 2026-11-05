//! Combine = ROM's `users.combine(:posts)`.
//!
//! `users.combine(.posts, posts)` names an association declared on the
//! users schema (see schema.zig) and the relation to read its rows from. The
//! result is a `Combined` relation, as lazy as any other: nothing is read
//! until `mapTo` or `mapWith`.
//!
//!     var result = try users.where(.deleted_at, .eq, null)
//!         .combine(.posts, posts.where(.published, .eq, true))
//!         .mapTo(Author, allocator);
//!     defer result.deinit();
//!     for (result.items) |author| ... author.posts ...
//!
//! ## Where the associated rows come from
//!
//! The associated relation is passed in. It can be any relation over the
//! association's target schema, with its own filters and order, so
//! `posts.where(.published, .eq, true)` combines only published posts. With
//! a `zom.Container`, pass the container's relation:
//! `app.relations.users.combine(.posts, app.relations.posts)`.
//!
//! ## How a combined read runs
//!
//! 1. The source relation is read once, with its filters, order and limit.
//! 2. The distinct keys of those rows are collected: the primary key for a
//!    `hasMany`, the foreign key for a `belongsTo` (rows whose optional
//!    foreign key is null are skipped).
//! 3. The associated relation is read with `whereIn(key, keys)`, one query
//!    per `Query.max_in` keys, so ⌈keys / max_in⌉ queries (none when there
//!    are no keys). Each key is in exactly one query, so every group keeps
//!    the associated relation's order.
//! 4. The rows are grouped by key with a hash map from the key to its
//!    position in the key list, then a counting pass, so a `hasMany`'s
//!    children all go into one slice and each parent gets a sub-slice of it.
//!    That is O(n + m) and makes two allocations, where a
//!    `HashMap(Key, ArrayList(Child))` makes one per parent. (Sorting the
//!    children by key and grouping runs needs no hashing but is O(m log m),
//!    and would lose the associated relation's order unless the sort is
//!    stable on a copy.)
//! 5. Each source row is mapped to the entity, and the field named after
//!    the association gets its rows: a slice for `hasMany` (empty when there
//!    are none), an optional for `belongsTo` (null when the foreign key is
//!    null or its row was filtered out). Associated rows whose key matches
//!    no source row are dropped.
//!
//! The associated relation's `limit` and `offset` would apply to each
//! batched query, not to each group, so a paged associated relation is
//! `error.PagedCombineTarget`.
//!
//! ## Memory
//!
//! The result is a tree: entities pointing at slices of entities, pointing
//! at strings. `mapTo` returns a `Result` whose arena owns every part of it,
//! including the strings of a caller-owned adapter such as zom-pg, so one
//! `result.deinit()` frees it all. Scratch space (the key list and the hash
//! map) is taken from the allocator passed in and freed before returning.
//!
//! TODO(#43): nested combines, `users.combine(.posts.combine(.comments))`,
//! are not done yet. Combining the children's relation would need
//! `Combined` to be readable as a target, i.e. a `toSlice` into the parent's
//! arena that the outer combine can call per batch.

const std = @import("std");
const schema = @import("schema.zig");
const mapper = @import("mapper.zig");

/// Returned by `Combined.mapTo` and `Combined.mapWith`: the entities and
/// the arena that owns them and everything they point at.
pub fn Result(comptime E: type) type {
    return struct {
        items: []E,
        arena: std.heap.ArenaAllocator,

        /// Frees the entities, their associated rows and their strings.
        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

/// What `Relation.combine(.assoc, target)` returns. `Source` is the relation
/// combine was called on, `a` the association (declared on its schema), and
/// `Target` the relation the associated rows are read from.
pub fn Combined(comptime Source: type, comptime a: schema.Association, comptime Target: type) type {
    const label = "zom.combine(." ++ a.name ++ ") on relation '" ++ Source.schema.name ++ "'";
    if (!isRelation(Target))
        @compileError(label ++ ": the second argument must be a relation over schema \"" ++ a.target.name ++
            "\", found `" ++ @typeName(Target) ++ "`");
    if (Target.schema != a.target)
        @compileError(label ++ ": the second argument must be a relation over schema \"" ++ a.target.name ++
            "\", found one over \"" ++ Target.schema.name ++ "\"");

    // The key field on each side: has-many joins the source's primary key to
    // the target's foreign key, belongs-to the source's foreign key to the
    // target's primary key.
    const source_key = if (a.kind == .has_many) a.primary_key else a.foreign_key;
    const target_key = if (a.kind == .has_many) a.foreign_key else a.primary_key;
    requireField(Source.Output, source_key, label, "the relation it is called on");
    requireField(Target.Output, target_key, label, "the relation passed to it");
    const Key = Unwrap(@FieldType(a.Parent().Tuple, a.primary_key));

    return struct {
        const Self = @This();

        pub const association = a;

        source: Source,
        target: Target,

        /// Each source row mapped to `E` by attribute name, as
        /// `Relation.mapTo` does, with the field named after the
        /// association set to its rows. That field is `[]const X` for a
        /// `hasMany` and `?X` for a `belongsTo`, where `X` is the target's
        /// row type or any struct `zom.Mapper` can map it to. It needs no
        /// default. Free the result with `result.deinit()`.
        pub fn mapTo(self: Self, comptime E: type, allocator: std.mem.Allocator) !Result(E) {
            return self.run(mapper.Mapper(Source.Output, E, .{ .skip = &.{a.name} }), allocator);
        }

        /// `mapTo` through a `zom.Mapper` for the source rows, e.g. one with
        /// renames. `M.Input` is the source relation's `Output`. The
        /// association field is filled here, so `M` need not give it a
        /// default.
        pub fn mapWith(self: Self, comptime M: type, allocator: std.mem.Allocator) !Result(M.Output) {
            if (M.Input != Source.Output)
                @compileError(label ++ ": mapWith needs a mapper from `" ++ @typeName(Source.Output) ++
                    "`, found one from `" ++ @typeName(M.Input) ++ "`");
            if (comptime !@hasDecl(M, "options")) return self.run(M, allocator);
            const opts = comptime blk: {
                var o = M.options;
                o.skip = o.skip ++ &[_][]const u8{a.name};
                break :blk o;
            };
            return self.run(mapper.Mapper(M.Input, M.Output, opts), allocator);
        }

        fn run(self: Self, comptime M: type, allocator: std.mem.Allocator) !Result(M.Output) {
            const E = M.Output;
            const X = AssocElem(E);
            if (self.target.query.limit != null or self.target.query.offset != 0)
                return error.PagedCombineTarget;

            var result: Result(E) = .{ .items = &.{}, .arena = .init(allocator) };
            errdefer result.arena.deinit();
            const arena = result.arena.allocator();

            const sources = try self.source.toSlice(arena);

            // Distinct source keys, in first-seen order, and where each is.
            var keys: std.ArrayList(Key) = .empty;
            defer keys.deinit(allocator);
            var index: KeyMap(u32) = .empty;
            defer index.deinit(allocator);
            try index.ensureTotalCapacity(allocator, @intCast(sources.len));
            for (sources) |row| {
                const key = keyOf(@field(row, source_key)) orelse continue;
                const gop = index.getOrPutAssumeCapacity(key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(keys.items.len);
                    try keys.append(allocator, key);
                }
            }

            // One target query per `max_in` keys.
            var batches: std.ArrayList([]const Target.Output) = .empty;
            defer batches.deinit(allocator);
            const field = comptime std.meta.stringToEnum(Target.Field, target_key).?;
            const max_in = Target.Q.max_in;
            var start: usize = 0;
            while (start < keys.items.len) : (start += max_in) {
                const chunk = keys.items[start..@min(start + max_in, keys.items.len)];
                try batches.append(allocator, try self.target.whereIn(field, chunk).toSlice(arena));
            }

            const items = try arena.alloc(E, sources.len);
            switch (a.kind) {
                .has_many => {
                    // Count each group, give it a range of one slice, fill it.
                    const offsets = try allocator.alloc(u32, keys.items.len + 1);
                    defer allocator.free(offsets);
                    @memset(offsets, 0);
                    var total: u32 = 0;
                    for (batches.items) |rows| for (rows) |row| {
                        const g = group(&index, @field(row, target_key)) orelse continue;
                        offsets[g + 1] += 1;
                        total += 1;
                    };
                    for (1..offsets.len) |g| offsets[g] += offsets[g - 1];
                    const children = try arena.alloc(X, total);
                    const cursor = try allocator.dupe(u32, offsets[0..keys.items.len]);
                    defer allocator.free(cursor);
                    for (batches.items) |rows| for (rows) |row| {
                        const g = group(&index, @field(row, target_key)) orelse continue;
                        children[cursor[g]] = mapElem(X, row);
                        cursor[g] += 1;
                    };
                    for (sources, items) |row, *item| {
                        item.* = M.call(row);
                        const g = group(&index, @field(row, source_key));
                        @field(item.*, a.name) = if (g) |i| children[offsets[i]..offsets[i + 1]] else &.{};
                    }
                },
                .belongs_to => {
                    // One parent per key; the first one read wins.
                    const parents = try allocator.alloc(?X, keys.items.len);
                    defer allocator.free(parents);
                    @memset(parents, null);
                    for (batches.items) |rows| for (rows) |row| {
                        const g = group(&index, @field(row, target_key)) orelse continue;
                        if (parents[g] == null) parents[g] = mapElem(X, row);
                    };
                    for (sources, items) |row, *item| {
                        item.* = M.call(row);
                        const g = group(&index, @field(row, source_key));
                        @field(item.*, a.name) = if (g) |i| parents[i] else null;
                    }
                },
            }
            result.items = items;
            return result;
        }

        /// The association field's element type in `E`, checked.
        fn AssocElem(comptime E: type) type {
            const where = label ++ ": `" ++ @typeName(E) ++ "`";
            if (@typeInfo(E) != .@"struct" or !@hasField(E, a.name))
                @compileError(where ++ " needs a field `" ++ a.name ++ "` to hold the association");
            const F = @FieldType(E, a.name);
            const want = if (a.kind == .has_many) "a slice `[]const T`" else "an optional `?T`";
            const info = @typeInfo(F);
            const fits = switch (a.kind) {
                .has_many => info == .pointer and info.pointer.size == .slice,
                .belongs_to => info == .optional,
            };
            if (!fits)
                @compileError(where ++ "." ++ a.name ++ " must be " ++ want ++ ", found `" ++ @typeName(F) ++ "`");
            const X = if (a.kind == .has_many) info.pointer.child else info.optional.child;
            if (@typeInfo(X) != .@"struct")
                @compileError(where ++ "." ++ a.name ++ " must be " ++ want ++ " of a struct, found `" ++ @typeName(F) ++ "`");
            return X;
        }

        fn mapElem(comptime X: type, row: Target.Output) X {
            if (X == Target.Output) return row;
            return mapper.Mapper(Target.Output, X, .{}).call(row);
        }

        const KeyMap = if (Key == []const u8)
            std.StringHashMapUnmanaged
        else
            struct {
                fn Map(comptime V: type) type {
                    return std.AutoHashMapUnmanaged(Key, V);
                }
            }.Map;

        fn group(index: *const KeyMap(u32), value: anytype) ?u32 {
            return index.get(keyOf(value) orelse return null);
        }

        fn keyOf(value: anytype) ?Key {
            return value;
        }
    };
}

fn requireField(comptime T: type, comptime name: []const u8, comptime label: []const u8, comptime which: []const u8) void {
    if (!@hasField(T, name))
        @compileError(label ++ ": key '" ++ name ++ "' is not read by " ++ which ++
            " (it reads `" ++ @typeName(T) ++ "`); add it to its `select`");
}

fn Unwrap(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

fn isRelation(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "schema") and @hasDecl(T, "Output") and
        @hasDecl(T, "Q") and @hasField(T, "query");
}
