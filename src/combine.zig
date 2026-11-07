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
//! ## Per-parent paging
//!
//! The associated relation's `limit` and `offset` page each parent's rows:
//! `users.combine(.posts, posts.order(.id, .desc).limit(3))` gives every
//! user their latest three posts. Applied to the query they would page each
//! batch of ⌈keys / max_in⌉, which means nothing, so they are taken off it:
//! every matching row is read, as without them, and each group keeps the
//! rows after its first `offset`, at most `limit` of them, in the
//! relation's order. A `belongsTo` parent is the first row of its page
//! (so `offset(1)` leaves it null). A nested level fills only the rows
//! kept. A `loadAssociation` gets the query without them too, and its
//! groups are paged the same way.
//!
//! The cost is reading the whole association. Pushing the page into the
//! query (SQL's `ROW_NUMBER() OVER (PARTITION BY ...)`) is left to a later
//! adapter capability (#87).
//!
//! ## A dataset that loads associations itself: `loadAssociation`
//!
//! Steps 3 and 4 are an `in` query and a hash map, which only work when
//! each associated row holds one key. A dataset can do them its own way
//! by declaring
//!
//!     pub fn loadAssociation(
//!         self: *Self,
//!         comptime a: zom.Association,
//!         keys: []const a.Key(),
//!         query: zom.Query(S.Tuple),
//!         allocator: std.mem.Allocator,
//!     ) ![]const []const S.Tuple
//!
//! `@hasDecl(Dataset, "loadAssociation")` decides, at compile time: when it
//! is declared, every combine *into* that dataset calls it once, with the
//! distinct source keys from step 2 (any number of them) and the
//! associated relation's whole query (less its limit and offset, which
//! combine applies to each key's slice afterwards), and the generic steps 3
//! and 4 don't run. It returns one slice per key, in the order of `keys`: that key's
//! rows, ordered as the query says. It must honour every filter and order
//! of `query`, including those a `.fallback` relation would have evaluated
//! in memory (`Query.matches` and `Query.lessThan` do both). A row may be
//! in several keys' slices. Everything returned is allocated with
//! `allocator`, the result's arena, so the dataset frees nothing.
//!
//! For `a.cardinality == .one` the first row of each slice is the parent.
//! The call is one instrumentation span (`.read`, with the associated
//! query); a `.fallback` target's scan hook is not called, since the
//! dataset ran the whole query.
//!
//! A `zom.customAssociation`, which has no foreign key for steps 3 and 4,
//! can only be combined through `loadAssociation`; without one it is a
//! compile error. zom-tigerbeetle's transfers dataset loads
//! `Account.transfers` this way: a transfer belongs to an account as its
//! debit *or* its credit account, and `get_account_transfers` finds both,
//! where an `in` query on one key field could not.
//!
//! ## Nested combines
//!
//! The target can itself be a `Combined`:
//!
//!     users.combine(.posts, posts.combine(.comments, comments)).mapTo(Author, allocator)
//!
//! The rows are then read from the inner combine's source relation
//! (`posts`, with its filters and order), and the inner combine fills
//! their association. The element type of `Author.posts` (say
//! `PostWithComments`) is what each post row maps to, by attribute name,
//! and it needs a `comments` field of the right shape: the same checks run
//! at every level.
//!
//! Every level runs once, on all the rows of the level above: the inner
//! level gets the posts of every batch in one slice, so it makes
//! ⌈post keys / max_in⌉ queries, not that many per outer batch. A whole
//! combine is one source read plus Σ ⌈keys / max_in⌉ over its levels. That
//! is why `fill` takes rows already read rather than the inner combine
//! being read per batch with `whereIn(...).toSlice`. Through
//! `loadAssociation` the rows are whole tuples, flattened in key order, so
//! the inner `fill` takes them as `M.Input` and each key's group is a
//! sub-slice of the filled elements; a row in several groups is filled once
//! per copy.
//!
//! ## Memory
//!
//! The result is a tree: entities pointing at slices of entities, pointing
//! at strings. `mapTo` returns a `Result` whose arena owns every part of it,
//! including the strings of a caller-owned adapter such as zom-pg, so one
//! `result.deinit()` frees it all. Scratch space (the key list and the hash
//! map) is taken from the allocator passed in and freed before returning.
//! A nested combine's levels all allocate in that one arena.

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
/// `Target` the relation the associated rows are read from, or another
/// `Combined` over such a relation (a nested combine).
pub fn Combined(comptime Source: type, comptime a: schema.Association, comptime Target: type) type {
    const label = "zom.combine(." ++ a.name ++ ") on relation '" ++ Source.schema.name ++ "'";
    // A nested combine: the associated rows are read from the inner
    // combine's source relation, and the inner combine fills their own
    // association.
    const nested = isCombined(Target);
    const Rel = if (nested) Target.SourceRelation else Target;
    if (!isRelation(Rel))
        @compileError(label ++ ": the second argument must be a relation over schema \"" ++ a.target.name ++
            "\" (or a combine of one), found `" ++ @typeName(Target) ++ "`");
    if (Rel.schema != a.target)
        @compileError(label ++ ": the second argument must be a relation over schema \"" ++ a.target.name ++
            "\", found one over \"" ++ Rel.schema.name ++ "\"");

    // The target's dataset loads the rows itself, or the rows are read with
    // `whereIn` and grouped here. A custom association has no other way.
    const hooked = @hasDecl(Rel.DatasetT, "loadAssociation");
    if (a.kind == .custom and !hooked)
        @compileError(label ++ ": '" ++ a.name ++ "' is a custom association (`." ++ a.tag ++ "`), which the dataset of \"" ++
            a.target.name ++ "\" must load, but adapter '" ++ Rel.Adapter.name ++ "' declares no `loadAssociation` on it");

    // The key field on each side: has-many joins the source's primary key to
    // the target's foreign key, belongs-to the source's foreign key to the
    // target's primary key. A custom association groups by the source's
    // primary key, and only its dataset knows the target's side.
    const source_key = if (a.kind == .belongs_to) a.foreign_key else a.primary_key;
    const target_key = switch (a.kind) {
        .has_many => a.foreign_key,
        .belongs_to => a.primary_key,
        .custom => "",
    };
    requireField(Source.Output, source_key, label, "the relation it is called on");
    if (!hooked) requireField(Rel.Output, target_key, label, "the relation passed to it");
    const Key = a.Key();

    return struct {
        const Self = @This();

        pub const association = a;
        /// The relation `combine` was called on.
        pub const SourceRelation = Source;
        /// What was passed to `combine`: a relation, or a nested `Combined`.
        pub const TargetRelation = Target;

        source: Source,
        target: Target,

        /// Each source row mapped to `E` by attribute name, as
        /// `Relation.mapTo` does, with the field named after the
        /// association set to its rows. That field is `[]const X` for a
        /// `hasMany` and `?X` for a `belongsTo`, where `X` is the target's
        /// row type or any struct `zom.Mapper` can map it to. It needs no
        /// default. For a nested combine, `X` is mapped by attribute name
        /// too and has a field for the inner association, filled the same
        /// way, at every level. Free the result with `result.deinit()`.
        pub fn mapTo(self: Self, comptime E: type, allocator: std.mem.Allocator) !Result(E) {
            return self.run(mapper.Mapper(Source.Output, E, .{ .skip = &.{a.name} }), allocator);
        }

        /// `mapTo` through a `zom.Mapper` for the source rows, e.g. one with
        /// renames. `M.Input` is the source relation's `Output`. The
        /// association field is filled here, so `M` need not give it a
        /// default. Nested levels map by attribute name.
        pub fn mapWith(self: Self, comptime M: type, allocator: std.mem.Allocator) !Result(M.Output) {
            if (M.Input != Source.Output)
                @compileError(label ++ ": mapWith needs a mapper from `" ++ @typeName(Source.Output) ++
                    "`, found one from `" ++ @typeName(M.Input) ++ "`");
            return self.run(withSkip(M), allocator);
        }

        /// `M` with the association field added to its `skip`.
        fn withSkip(comptime M: type) type {
            if (comptime !@hasDecl(M, "options")) return M;
            const opts = comptime blk: {
                var o = M.options;
                o.skip = o.skip ++ &[_][]const u8{a.name};
                break :blk o;
            };
            return mapper.Mapper(M.Input, M.Output, opts);
        }

        fn run(self: Self, comptime M: type, allocator: std.mem.Allocator) !Result(M.Output) {
            var result: Result(M.Output) = .{ .items = &.{}, .arena = .init(allocator) };
            errdefer result.arena.deinit();
            const arena = result.arena.allocator();

            const sources = try self.source.toSlice(arena);
            const items = try arena.alloc(M.Output, sources.len);
            try self.fill(M, sources, items, arena, allocator);
            result.items = items;
            return result;
        }

        /// Steps 2 to 5 on source rows already read: `items[i]` is
        /// `sources[i]` mapped through `M`, with its association filled.
        /// `M.Input` is `Source.Output`, or, when this is the inner level
        /// of a nested combine fed by a `loadAssociation`, the whole tuple.
        /// Everything kept is allocated in `arena`; scratch space comes
        /// from `scratch` and is freed before returning. A nested target's
        /// own `fill` runs once, on every row read here.
        fn fill(
            self: Self,
            comptime M: type,
            sources: []const M.Input,
            items: []M.Output,
            arena: std.mem.Allocator,
            scratch: std.mem.Allocator,
        ) !void {
            const X = AssocElem(M.Output);
            // The target's limit and offset page each parent's rows, so
            // they are taken off the query and applied per group below.
            const page: Page = .of(self.relation().query);
            const target = page.strip(self.relation());

            // Distinct source keys, in first-seen order, and where each is.
            var keys: std.ArrayList(Key) = .empty;
            defer keys.deinit(scratch);
            var index: KeyMap(u32) = .empty;
            defer index.deinit(scratch);
            try index.ensureTotalCapacity(scratch, @intCast(sources.len));
            for (sources) |row| {
                const key = keyOf(@field(row, source_key)) orelse continue;
                const gop = index.getOrPutAssumeCapacity(key);
                if (!gop.found_existing) {
                    gop.value_ptr.* = @intCast(keys.items.len);
                    try keys.append(scratch, key);
                }
            }

            if (comptime hooked)
                return self.fillLoaded(M, X, target, page, sources, items, keys.items, &index, arena, scratch);

            // One target query per `max_in` keys, all rows in one slice.
            var batches: std.ArrayList([]const Rel.Output) = .empty;
            defer batches.deinit(scratch);
            const field = comptime std.meta.stringToEnum(Rel.Field, target_key).?;
            const max_in = Rel.Q.max_in;
            var start: usize = 0;
            while (start < keys.items.len) : (start += max_in) {
                const chunk = keys.items[start..@min(start + max_in, keys.items.len)];
                try batches.append(scratch, try target.whereIn(field, chunk).toSlice(arena));
            }
            const joined = batches.items.len > 1;
            const read: []const Rel.Output = switch (batches.items.len) {
                0 => &.{},
                1 => batches.items[0],
                else => try std.mem.concat(scratch, Rel.Output, batches.items),
            };
            defer if (joined) scratch.free(read);
            // Each parent's page of its rows, before a nested level fills
            // them, so the next level reads only the rows kept here.
            const rows = if (page.active()) try pageRows(read, &index, keys.items.len, page, scratch) else read;
            defer if (page.active()) scratch.free(rows);

            // The element of each target row. A nested target fills them
            // all at once, so the next level makes ⌈keys / max_in⌉ queries
            // over every row read here, not per batch.
            const elems: []const X = if (comptime nested) blk: {
                const out = try arena.alloc(X, rows.len);
                try self.target.fill(innerMapper(Rel.Output, X), rows, out, arena, scratch);
                break :blk out;
            } else &.{};

            switch (a.cardinality) {
                .many => {
                    // Count each group, give it a range of one slice, fill it.
                    const offsets = try scratch.alloc(u32, keys.items.len + 1);
                    defer scratch.free(offsets);
                    @memset(offsets, 0);
                    var total: u32 = 0;
                    for (rows) |row| {
                        const g = group(&index, @field(row, target_key)) orelse continue;
                        offsets[g + 1] += 1;
                        total += 1;
                    }
                    for (1..offsets.len) |g| offsets[g] += offsets[g - 1];
                    const children = try arena.alloc(X, total);
                    const cursor = try scratch.dupe(u32, offsets[0..keys.items.len]);
                    defer scratch.free(cursor);
                    for (rows, 0..) |row, i| {
                        const g = group(&index, @field(row, target_key)) orelse continue;
                        children[cursor[g]] = if (comptime nested) elems[i] else mapElem(X, row);
                        cursor[g] += 1;
                    }
                    for (sources, items) |row, *item| {
                        item.* = M.call(row);
                        const g = group(&index, @field(row, source_key));
                        @field(item.*, a.name) = if (g) |i| children[offsets[i]..offsets[i + 1]] else &.{};
                    }
                },
                .one => {
                    // One parent per key; the first one read wins.
                    const parents = try scratch.alloc(?X, keys.items.len);
                    defer scratch.free(parents);
                    @memset(parents, null);
                    for (rows, 0..) |row, i| {
                        const g = group(&index, @field(row, target_key)) orelse continue;
                        if (parents[g] == null) parents[g] = if (comptime nested) elems[i] else mapElem(X, row);
                    }
                    for (sources, items) |row, *item| {
                        item.* = M.call(row);
                        const g = group(&index, @field(row, source_key));
                        @field(item.*, a.name) = if (g) |i| parents[i] else null;
                    }
                },
            }
        }

        /// Steps 3 to 5 through the target dataset's `loadAssociation`:
        /// one call for every key, then each source row gets its key's
        /// rows (the first of them for `.one`).
        fn fillLoaded(
            self: Self,
            comptime M: type,
            comptime X: type,
            target: Rel,
            page: Page,
            sources: []const M.Input,
            items: []M.Output,
            keys: []const Key,
            index: *const KeyMap(u32),
            arena: std.mem.Allocator,
            scratch: std.mem.Allocator,
        ) !void {
            const query = target.query;
            const span = target.instrument(.read, &query);
            const all = try span.end(target.dataset.loadAssociation(a, keys, query, arena));
            if (all.len != keys.len)
                std.debug.panic("zom: adapter '{s}': loadAssociation(.{s}) returned {d} groups for {d} keys", .{
                    Rel.Adapter.name, a.name, all.len, keys.len,
                });
            // Each key's page of its rows; the slices point into `all`.
            const loaded: []const []const Rel.Tuple = if (page.active()) blk: {
                const out = try scratch.alloc([]const Rel.Tuple, all.len);
                for (all, out) |rows, *o| o.* = page.window(Rel.Tuple, rows);
                break :blk out;
            } else all;
            defer if (page.active()) scratch.free(loaded);

            // Every row this level keeps, mapped to `X`, in one slice:
            // each key's rows for `.many`, its first row for `.one`. A
            // nested target fills them all in one go.
            var total: usize = 0;
            for (loaded) |rows| total += if (a.cardinality == .many) rows.len else @min(rows.len, 1);
            const elems = try arena.alloc(X, total);
            if (comptime nested) {
                const flat = try scratch.alloc(Rel.Tuple, total);
                defer scratch.free(flat);
                var at: usize = 0;
                for (loaded) |rows| {
                    const kept = if (a.cardinality == .many) rows else rows[0..@min(rows.len, 1)];
                    @memcpy(flat[at..][0..kept.len], kept);
                    at += kept.len;
                }
                try self.target.fill(innerMapper(Rel.Tuple, X), flat, elems, arena, scratch);
            } else {
                var at: usize = 0;
                for (loaded) |rows| {
                    const kept = if (a.cardinality == .many) rows else rows[0..@min(rows.len, 1)];
                    for (kept) |row| {
                        elems[at] = fromTuple(X, row);
                        at += 1;
                    }
                }
            }

            switch (a.cardinality) {
                .many => {
                    const groups = try arena.alloc([]const X, keys.len);
                    var at: usize = 0;
                    for (loaded, groups) |rows, *g| {
                        g.* = elems[at..][0..rows.len];
                        at += rows.len;
                    }
                    for (sources, items) |row, *item| {
                        item.* = M.call(row);
                        const g = group(index, @field(row, source_key));
                        @field(item.*, a.name) = if (g) |i| groups[i] else &.{};
                    }
                },
                .one => {
                    const parents = try scratch.alloc(?X, keys.len);
                    defer scratch.free(parents);
                    var at: usize = 0;
                    for (loaded, parents) |rows, *p| {
                        p.* = if (rows.len > 0) elems[at] else null;
                        if (rows.len > 0) at += 1;
                    }
                    for (sources, items) |row, *item| {
                        item.* = M.call(row);
                        const g = group(index, @field(row, source_key));
                        @field(item.*, a.name) = if (g) |i| parents[i] else null;
                    }
                },
            }
        }

        /// `rows` with only each group's page kept, in order: per group,
        /// the rows after the first `page.offset`, at most `page.limit` of
        /// them. Rows matching no group are dropped. Owned by `scratch`.
        fn pageRows(
            rows: []const Rel.Output,
            index: *const KeyMap(u32),
            n_keys: usize,
            page: Page,
            scratch: std.mem.Allocator,
        ) ![]const Rel.Output {
            const seen = try scratch.alloc(usize, n_keys);
            defer scratch.free(seen);
            @memset(seen, 0);
            var kept: std.ArrayList(Rel.Output) = .empty;
            errdefer kept.deinit(scratch);
            for (rows) |row| {
                const g = group(index, @field(row, target_key)) orelse continue;
                const n = seen[g];
                seen[g] += 1;
                if (page.keeps(n)) try kept.append(scratch, row);
            }
            return kept.toOwnedSlice(scratch);
        }

        /// The relation the associated rows are read from.
        fn relation(self: Self) Rel {
            return if (comptime nested) self.target.source else self.target;
        }

        /// How a nested level's rows (`Row`, its source relation's output
        /// or tuple) map to `X`: by attribute name, leaving the inner
        /// association for the inner `fill`.
        fn innerMapper(comptime Row: type, comptime X: type) type {
            return mapper.Mapper(Row, X, .{ .skip = &.{Target.association.name} });
        }

        /// A whole tuple from `loadAssociation` as the association field's
        /// element. A `select` on the target narrows `Rel.Output`; any
        /// `X` mapped from that maps the same from the whole tuple.
        fn fromTuple(comptime X: type, row: Rel.Tuple) X {
            if (X == Rel.Tuple) return row;
            return mapper.Mapper(Rel.Tuple, X, .{}).call(row);
        }

        /// The association field's element type in `E`, checked.
        fn AssocElem(comptime E: type) type {
            const where = label ++ ": `" ++ @typeName(E) ++ "`";
            if (@typeInfo(E) != .@"struct" or !@hasField(E, a.name))
                @compileError(where ++ " needs a field `" ++ a.name ++ "` to hold the association");
            const F = @FieldType(E, a.name);
            const want = if (a.cardinality == .many) "a slice `[]const T`" else "an optional `?T`";
            const info = @typeInfo(F);
            const fits = switch (a.cardinality) {
                .many => info == .pointer and info.pointer.size == .slice,
                .one => info == .optional,
            };
            if (!fits)
                @compileError(where ++ "." ++ a.name ++ " must be " ++ want ++ ", found `" ++ @typeName(F) ++ "`");
            const X = if (a.cardinality == .many) info.pointer.child else info.optional.child;
            if (@typeInfo(X) != .@"struct")
                @compileError(where ++ "." ++ a.name ++ " must be " ++ want ++ " of a struct, found `" ++ @typeName(F) ++ "`");
            return X;
        }

        fn mapElem(comptime X: type, row: Rel.Output) X {
            if (X == Rel.Output) return row;
            return mapper.Mapper(Rel.Output, X, .{}).call(row);
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

/// A combine target's `limit` and `offset`, which page each parent's
/// associated rows rather than the target query.
const Page = struct {
    offset: usize = 0,
    limit: ?usize = null,

    fn of(query: anytype) Page {
        return .{ .offset = query.offset, .limit = query.limit };
    }

    fn active(p: Page) bool {
        return p.limit != null or p.offset != 0;
    }

    /// `rel` with no limit or offset: the query that reads every row.
    fn strip(_: Page, rel: anytype) @TypeOf(rel) {
        var r = rel;
        r.query.limit = null;
        r.query.offset = 0;
        return r;
    }

    /// Whether a group's `n`th row (from 0) is on the page.
    fn keeps(p: Page, n: usize) bool {
        if (n < p.offset) return false;
        return if (p.limit) |l| n - p.offset < l else true;
    }

    /// The page of one group's rows.
    fn window(p: Page, comptime R: type, rows: []const R) []const R {
        const start = @min(p.offset, rows.len);
        const end = if (p.limit) |l| @min(rows.len, start +| l) else rows.len;
        return rows[start..end];
    }
};

fn requireField(comptime T: type, comptime name: []const u8, comptime label: []const u8, comptime which: []const u8) void {
    if (!@hasField(T, name))
        @compileError(label ++ ": key '" ++ name ++ "' is not read by " ++ which ++
            " (it reads `" ++ @typeName(T) ++ "`); add it to its `select`");
}

fn isRelation(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "schema") and @hasDecl(T, "Output") and
        @hasDecl(T, "Q") and @hasDecl(T, "DatasetT") and @hasField(T, "query");
}

fn isCombined(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "association") and @hasDecl(T, "SourceRelation") and
        @hasDecl(T, "TargetRelation") and @hasField(T, "source") and @hasField(T, "target");
}
