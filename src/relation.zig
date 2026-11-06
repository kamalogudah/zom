//! Relation = ROM's `ROM::Relation`.
//!
//! A relation is a cheap, immutable value: a pointer to an adapter dataset
//! plus a query. Every chained call (`where`, `order`, `limit`) returns a new
//! relation, exactly like `users.where(...).order(...)` in ROM. Nothing hits
//! the dataset until you materialize it (`toSlice`, `one`, `mapTo`, ...).
//!
//! The adapter contract is checked at compile time by `zom.Adapter` (see
//! adapter.zig). `create`, `update` and `delete` need the matching dataset
//! capability (`createMany` needs `batch_insert` or `writable`), and fail to
//! compile, naming the adapter, when it is missing.
//! Zig only analyses a function that is called, so a relation over a
//! read-only adapter compiles fine as long as only its reads are used.
//!
//! `select(.{ .id, .name })` returns a relation whose reads give a narrower
//! struct (see projection.zig). Its query stays typed on the full tuple, so
//! filters and orders on attributes that were not selected still work, as
//! in `SELECT name FROM users WHERE age > 3`.
//!
//! Query support (plan.md section 3.1). Each relation has a `Mode`, part of
//! its type, for the query features its dataset's `supports` (and
//! `filterable`) leave out:
//!
//! - `.strict`, the default: using one is a compile error naming the
//!   adapter, the relation, the call and the missing feature, e.g. `where(
//!   .amount, .lt, ...)` on a dataset whose `filterable` rejects it.
//! - `.fallback`, turned on with `allowFallback()`: every read splits the
//!   query. The top-level conditions the dataset supports go to
//!   `dataset.read`, and zom evaluates the others on the rows it returns,
//!   with `Query.matches`. Once anything runs in memory, `order` (if the
//!   dataset can't do it), `offset` and `limit` run in memory too, after the
//!   filter, or pages would come back short.
//!
//! The cost of `.fallback` is the hidden full scan: a read whose filter runs
//! in memory fetches every row matching the supported part, with no limit,
//! however small the page asked for. That is why it must be turned on per
//! relation, and why every such read calls the relation's scan hook (see
//! `Scan`), which a `Container` sets on all its relations.

const std = @import("std");
const q = @import("query.zig");
const mapper = @import("mapper.zig");
const changeset = @import("changeset.zig");
const plugins = @import("plugins.zig");
const adapter = @import("adapter.zig");
const projection = @import("projection.zig");
const strings = @import("strings.zig");
const combine_mod = @import("combine.zig");
const pagination = @import("pagination.zig");

/// What a relation does with a query feature its dataset does not support.
pub const Mode = enum {
    /// A compile error.
    strict,
    /// Evaluated in memory, on the rows the dataset returns for the rest.
    fallback,
};

/// One read of a `.fallback` relation that evaluated part of its query in
/// memory, as reported to the scan hook. `rows_fetched` is what the dataset
/// returned, `rows_returned` what was left after the in-memory filter and
/// paging. A read the dataset evaluates entirely is not reported.
pub const Scan = struct {
    adapter: []const u8,
    relation: []const u8,
    rows_fetched: usize,
    rows_returned: usize,
};

/// Called once per `Scan`, e.g. to log it or count it in a test.
pub const ScanHook = *const fn (Scan) void;

/// A strict relation over schema `S`, reading whole tuples.
pub fn Relation(comptime S: type, comptime Gateway: type) type {
    return RelationWith(S, Gateway, S.Tuple, .strict);
}

/// A strict relation over schema `S` whose reads return `Out`: `S.Tuple`,
/// or a `zom.Project(S.Tuple, ...)` after `select`. `Relation(S, G)` is
/// `RelationOf(S, G, S.Tuple)`, the same type.
pub fn RelationOf(comptime S: type, comptime Gateway: type, comptime Out: type) type {
    return RelationWith(S, Gateway, Out, .strict);
}

/// The relation type itself: reads return `Out`, and `mode` says what
/// happens to query features the dataset does not support.
/// `allowFallback()` turns `RelationWith(S, G, Out, .strict)` into
/// `RelationWith(S, G, Out, .fallback)`.
pub fn RelationWith(comptime S: type, comptime Gateway: type, comptime Out: type, comptime relation_mode: Mode) type {
    return struct {
        const Self = @This();

        pub const schema = S;
        pub const mode = relation_mode;
        /// The stored tuple. Queries, filters and changes are typed on it.
        pub const Tuple = S.Tuple;
        /// What reads (`toSlice`, `one`, `first`) return.
        pub const Output = Out;
        /// True after `select`.
        pub const projected = Out != Tuple;
        pub const Q = q.Query(Tuple);
        pub const Field = Q.Field;
        pub const Adapter = adapter.Adapter(Gateway);
        pub const DatasetT = Adapter.Dataset(S);
        const supported = Adapter.supports(S);
        /// The dataset allocates the strings it returns with the read's
        /// allocator, so dropping a tuple means freeing them.
        const caller_owns = Adapter.stringOwnership(S) == .caller;

        dataset: *DatasetT,
        query: Q = .{},
        /// Called for each read that ran part of the query in memory. Only a
        /// `.fallback` relation ever calls it, but a strict one carries it
        /// so `allowFallback()` keeps it. Set by `Container`, or `onScan`.
        on_scan: ?ScanHook = null,
        /// What the schema's plugin hooks read, such as the clock. `void`
        /// when the schema has no plugins, so it costs nothing there. Set by
        /// `withPluginContext`, or `Container.setPluginContext`.
        plugin_context: PluginContext = if (PluginContext == void) {} else .{},

        pub const PluginContext = plugins.ContextField(S);

        pub fn init(gateway: *Gateway) !Self {
            return .{ .dataset = try gateway.dataset(S) };
        }

        // -- query support -------------------------------------------------

        /// The same relation in `.fallback` mode: features the dataset does
        /// not support compile, and run in memory (see the top of this file
        /// for the cost). Call it before or after building the query; every
        /// relation chained from the result is `.fallback` too.
        pub fn allowFallback(self: Self) RelationWith(S, Gateway, Out, .fallback) {
            return .{ .dataset = self.dataset, .query = self.query, .on_scan = self.on_scan, .plugin_context = self.plugin_context };
        }

        /// The same relation with `ctx` for its schema's plugins, e.g.
        /// `users.withPluginContext(.{ .clock = .{ .io = io } })`. A
        /// compile error when the schema has no plugins.
        pub fn withPluginContext(self: Self, ctx: plugins.Context) Self {
            if (PluginContext == void)
                @compileError("zom: `withPluginContext` on relation '" ++ S.name ++ "', whose schema has no plugins");
            var next = self;
            next.plugin_context = ctx;
            return next;
        }

        /// The same relation reporting in-memory reads to `hook` (null for
        /// none) instead of the hook it had.
        pub fn onScan(self: Self, hook: ?ScanHook) Self {
            var next = self;
            next.on_scan = hook;
            return next;
        }

        // -- query building (returns new relations) ------------------------

        /// See `Query.where` for what each op takes, e.g.
        /// `where(.id, .in, .{ 1, 2, 3 })`, `where(.name, .like, "Ach%")`,
        /// `where(.age, .between, .{ 18, 30 })`, `where(.age, .is_null, {})`.
        pub fn where(self: Self, comptime field: Field, comptime op: q.Op, value: anytype) Self {
            comptime requireFilter(field, op, "where(." ++ @tagName(field) ++ ", ." ++ @tagName(op) ++ ", ...)");
            var next = self;
            next.query = self.query.where(field, op, value);
            return next;
        }

        /// `where(field, .in, ...)` for a runtime slice, at most
        /// `Q.max_in` long. The relation borrows `values` without copying,
        /// so it (and every relation chained from it) is invalid once that
        /// slice is freed or changed.
        pub fn whereIn(self: Self, comptime field: Field, values: anytype) Self {
            comptime requireFilter(field, .in, "whereIn(." ++ @tagName(field) ++ ", ...)");
            var next = self;
            next.query = self.query.whereIn(field, values);
            return next;
        }

        /// `whereIn` for `not_in`, with the same borrowing rule.
        pub fn whereNotIn(self: Self, comptime field: Field, values: anytype) Self {
            comptime requireFilter(field, .not_in, "whereNotIn(." ++ @tagName(field) ++ ", ...)");
            var next = self;
            next.query = self.query.whereNotIn(field, values);
            return next;
        }

        /// AND `conds` OR-ed together, e.g.
        /// `whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })`.
        /// Each condition is `.{ field, op, value }` as `where` takes it, or
        /// a nested `zom.any`, `zom.all` or `zom.not`. See `Query.whereAny`.
        pub fn whereAny(self: Self, conds: anytype) Self {
            var next = self;
            next.query = self.query.whereAny(conds);
            comptime requireGroup(q.Group(.any, @TypeOf(conds)), "whereAny(...)");
            return next;
        }

        /// AND NOT `cond`, e.g. `whereNot(.{ .age, .gt, 30 })`. Rows where
        /// `cond` is unknown (a null attribute) match neither `cond` nor its
        /// negation, as in SQL. See `Query.whereNot`.
        pub fn whereNot(self: Self, cond: anytype) Self {
            var next = self;
            next.query = self.query.whereNot(cond);
            comptime requireGroup(q.Not(@TypeOf(cond)), "whereNot(...)");
            return next;
        }

        pub fn byPk(self: Self, value: anytype) Self {
            return self.where(S.primary_key, .eq, value);
        }

        /// Adds a sort key after the ones already set: `.order(.a, .asc)
        /// .order(.b, .desc)` is `ORDER BY a ASC, b DESC`. At most
        /// `Query.max_orders` keys; past that, panics.
        pub fn order(self: Self, comptime field: Field, direction: q.Direction) Self {
            comptime requireOrder(field, "order(." ++ @tagName(field) ++ ", ...)");
            var next = self;
            next.query = self.query.order(field, direction);
            return next;
        }

        /// Replaces every sort key: `reorder(.{ .{ .role, .asc }, .{ .age,
        /// .desc } })`, or `reorder(.{})` for none. See `Query.reorder`.
        pub fn reorder(self: Self, keys: anytype) Self {
            var next = self;
            next.query = self.query.reorder(keys);
            inline for (@typeInfo(@TypeOf(keys)).@"struct".fields) |f| {
                const key_field: Field = comptime @typeInfo(f.type).@"struct".fields[0].defaultValue().?;
                comptime requireOrder(key_field, "reorder(.{ .{ ." ++ @tagName(key_field) ++ ", ... } })");
            }
            return next;
        }

        pub fn limit(self: Self, n: usize) Self {
            var next = self;
            next.query.limit = n;
            return next;
        }

        pub fn offset(self: Self, n: usize) Self {
            if (comptime mode == .strict and !supported.offset)
                unsupported("offset(...)", "`supports.offset` is false");
            var next = self;
            next.query.offset = n;
            return next;
        }

        /// Page `n` of the relation, counting from 1: `page(n).perPage(k)`
        /// reads `offset((n - 1) * k).limit(k)`, and its `paginate(allocator)`
        /// also returns the total. See pagination.zig.
        pub fn page(self: Self, n: anytype) pagination.Pager(Self) {
            if (comptime mode == .strict and !supported.offset)
                unsupported("page(...)", "`supports.offset` is false");
            return .{ .relation = self, .page = pagination.positive(Self, n, "page") };
        }

        /// ROM's `select(:id, :name)`: the same relation, reading only
        /// `fields`, a tuple of attribute names such as `.{ .id, .name }`.
        /// Reads return `zom.Project(Tuple, fields)`, which has only those
        /// fields, in that order. Filters and orders, before or after, may
        /// still use any attribute. On a relation that is already projected,
        /// `fields` must be among the ones selected. The primary key does
        /// not have to be selected. A dataset without `supports.projection`
        /// still runs it: zom reads whole tuples and maps them down.
        pub fn select(self: Self, comptime fields: anytype) Selected(fields) {
            return .{ .dataset = self.dataset, .query = self.query, .on_scan = self.on_scan, .plugin_context = self.plugin_context };
        }

        fn Selected(comptime fields: anytype) type {
            const P = projection.Project(Tuple, fields);
            if (projected) {
                for (@typeInfo(P).@"struct".fields) |f| {
                    if (!@hasField(Output, f.name))
                        @compileError("zom.select: '" ++ f.name ++ "' was not selected on this relation, so it cannot be selected again");
                }
            }
            return RelationWith(S, Gateway, P, mode);
        }

        // -- strict checks -------------------------------------------------
        //
        // Each runs at compile time, from the builder method that adds the
        // feature, so the error points at the call that needs it.

        fn requireFilter(comptime field: Field, comptime op: q.Op, comptime call: []const u8) void {
            if (mode == .fallback) return;
            if (Adapter.filterGap(S, @tagName(field), op)) |why| unsupported(call, why);
        }

        fn requireOrder(comptime field: Field, comptime call: []const u8) void {
            if (mode == .fallback) return;
            if (Adapter.orderGap(S, @tagName(field))) |why| unsupported(call, why);
        }

        /// A `whereAny` / `whereNot` group: the group itself needs
        /// `supports.or`, and each condition in it is checked like `where`.
        fn requireGroup(comptime C: type, comptime call: []const u8) void {
            if (mode == .fallback) return;
            if (!supported.@"or")
                unsupported(call, "boolean groups (`whereAny`, `whereNot`) need `supports.or`");
            requireCond(C, call);
        }

        /// Walks a condition's type: `Query.addCond` has already checked its
        /// shape, so every leaf is a tuple with a comptime field and op.
        fn requireCond(comptime C: type, comptime call: []const u8) void {
            if (@hasDecl(C, "zom_group")) {
                for (@typeInfo(@FieldType(C, "conds")).@"struct".fields) |f| requireCond(f.type, call);
            } else if (@hasDecl(C, "zom_not")) {
                requireCond(@FieldType(C, "cond"), call);
            } else {
                const fields = @typeInfo(C).@"struct".fields;
                const field: Field = fields[0].defaultValue().?;
                const op: q.Op = fields[1].defaultValue().?;
                if (Adapter.filterGap(S, @tagName(field), op)) |why|
                    unsupported(call ++ " with ." ++ @tagName(field) ++ ", ." ++ @tagName(op), why);
            }
        }

        fn unsupported(comptime call: []const u8, comptime why: []const u8) noreturn {
            @compileError("zom: adapter '" ++ Adapter.name ++ "' cannot evaluate `" ++ call ++ "` on relation '" ++
                S.name ++ "': " ++ why ++ "; call `allowFallback()` on the relation to evaluate it in memory instead");
        }

        // -- fallback plan -------------------------------------------------

        /// How a read runs: `pushed` goes to the dataset, and when
        /// `in_memory`, `rest` (the filters, sort keys, limit and offset the
        /// dataset can't run in that order) is applied to what it returns.
        const Plan = struct {
            pushed: Q,
            rest: Q = .{},
            in_memory: bool = false,
            /// `rest.orderSlice()` must be sorted on in memory.
            sort: bool = false,
        };

        /// A strict relation's query is fully supported, or it would not
        /// have compiled, so only `.fallback` splits.
        fn plan(self: *const Self) Plan {
            if (comptime mode == .strict) return .{ .pushed = self.query };
            return self.split();
        }

        fn split(self: *const Self) Plan {
            const query = &self.query;
            // A join is always the dataset's (see `requireJoin`).
            var p: Plan = .{ .pushed = .{ .join = query.join } };
            var it = query.topNodes();
            while (it.next()) |i| {
                const index: u8 = @intCast(i);
                if (nodePushable(query, index)) p.pushed.addNodeFrom(query, index) else p.rest.addNodeFrom(query, index);
            }
            const filters_pushed = p.rest.node_count == 0;
            const order_pushed = for (query.orderSlice()) |o| {
                if (!orderPushable(o.field)) break false;
            } else true;
            const offset_pushed = query.offset == 0 or supported.offset;
            if (filters_pushed and order_pushed and offset_pushed) return .{ .pushed = self.query };

            // Something runs in memory, so paging runs after it.
            for (query.orderSlice()) |o| {
                if (order_pushed) p.pushed.addOrder(o) else p.rest.addOrder(o);
            }
            p.sort = !order_pushed;
            p.rest.limit = query.limit;
            p.rest.offset = query.offset;
            // Only the offset is missing: the first `offset + limit` rows
            // are enough. Otherwise the in-memory filter or sort needs every
            // row the pushed part matches.
            if (filters_pushed and order_pushed) {
                if (query.limit) |l| p.pushed.limit = std.math.add(usize, l, query.offset) catch null;
            }
            p.in_memory = true;
            return p;
        }

        /// Whether the dataset can evaluate node `index` of `query`, with
        /// everything under it.
        fn nodePushable(query: *const Q, index: u8) bool {
            switch (query.nodes[index]) {
                .filter => |f| return filterPushable(query.filters[f]),
                .not => |child| return supported.@"or" and nodePushable(query, child),
                .and_group, .or_group => |g| {
                    if (!supported.@"or") return false;
                    for (g.first..g.first + g.len) |c| {
                        if (!nodePushable(query, @intCast(c))) return false;
                    }
                    return true;
                },
            }
        }

        fn filterPushable(f: Q.Filter) bool {
            return pushable.filter[@intFromEnum(f.field)][@intFromEnum(f.op)];
        }

        fn orderPushable(field: Field) bool {
            return pushable.order[@intFromEnum(field)];
        }

        /// Which filters and sort keys the dataset evaluates, worked out
        /// once per relation type: `filter[field][op]`, `order[field]`.
        const pushable: Pushable = blk: {
            @setEvalBranchQuota(1000 + 200 * field_count * op_count);
            var table: Pushable = undefined;
            for (std.enums.values(Field)) |field| {
                for (std.enums.values(q.Op)) |op|
                    table.filter[@intFromEnum(field)][@intFromEnum(op)] = Adapter.filterGap(S, @tagName(field), op) == null;
                table.order[@intFromEnum(field)] = Adapter.orderGap(S, @tagName(field)) == null;
            }
            const final = table;
            break :blk final;
        };
        const field_count = std.enums.values(Field).len;
        const op_count = std.enums.values(q.Op).len;
        const Pushable = struct {
            filter: [field_count][op_count]bool,
            order: [field_count]bool,
        };

        /// The tuples `p` describes: the dataset's rows for `p.pushed`,
        /// then, when `p.in_memory`, filtered, sorted and paged by `p.rest`.
        /// Caller frees the result with `allocator`.
        fn readTuples(self: Self, p: Plan, allocator: std.mem.Allocator) ![]Tuple {
            const span = self.instrument(.read, &p.pushed);
            const rows = try span.end(self.dataset.read(p.pushed, allocator));
            if (!p.in_memory) return rows;
            errdefer allocator.free(rows);

            // Until the compaction below, `rows[0..kept]` and `rows[i..]`
            // are the tuples whose strings are still owned here.
            var kept: usize = 0;
            var i: usize = 0;
            errdefer if (caller_owns) {
                for (rows[0..kept]) |row| dropStrings(allocator, row);
                for (rows[i..]) |row| dropStrings(allocator, row);
            };
            while (i < rows.len) : (i += 1) {
                const row = rows[i];
                if (p.rest.matches(row)) {
                    rows[kept] = row;
                    kept += 1;
                } else if (caller_owns) {
                    dropStrings(allocator, row);
                }
            }
            // Stable, like the memory adapter, so ties keep the dataset's order.
            if (p.sort) std.mem.sort(Tuple, rows[0..kept], p.rest.orderSlice(), Q.lessThan);
            const start = @min(p.rest.offset, kept);
            const len = if (p.rest.limit) |l| @min(l, kept - start) else kept - start;
            if (caller_owns) {
                for (rows[0..start]) |row| dropStrings(allocator, row);
                for (rows[start + len .. kept]) |row| dropStrings(allocator, row);
            }
            std.mem.copyForwards(Tuple, rows[0..len], rows[start..][0..len]);
            kept = len;

            const fetched = rows.len;
            const out = try allocator.realloc(rows, len);
            if (self.on_scan) |hook| hook(.{
                .adapter = Adapter.name,
                .relation = S.name,
                .rows_fetched = fetched,
                .rows_returned = len,
            });
            return out;
        }

        /// The query `update` and `delete` hand to the dataset. Writes never
        /// run in memory: on a `.fallback` relation whose filters the
        /// dataset can't all evaluate, this is `error.UnsupportedFilter`.
        /// On a joined relation it is `error.JoinedWrite`: which rows a
        /// join keeps depends on another dataset, and writes only ever
        /// filter on their own.
        pub fn writeQuery(self: Self) error{ UnsupportedFilter, JoinedWrite }!Q {
            if (self.query.join != null) return error.JoinedWrite;
            if (comptime mode == .strict) return self.query;
            var it = self.query.topNodes();
            while (it.next()) |i| {
                if (!nodePushable(&self.query, @intCast(i))) return error.UnsupportedFilter;
            }
            return self.query;
        }

        // -- materializing -------------------------------------------------

        /// Caller owns the returned slice: free it with `free(allocator,
        /// rows)`, which also frees the strings when the dataset's are
        /// caller-owned (see strings.zig). With a `.dataset` adapter (memory,
        /// CSV, YAML) the strings point into the dataset and stay valid as
        /// long as the gateway lives; with a `.caller` one (zom-pg) they
        /// belong to `allocator`.
        ///
        /// After `select`, a dataset with `supports.projection` reads the
        /// selected attributes itself (`readProjected`); any other dataset
        /// reads whole tuples, which zom maps down and frees. So does a
        /// `.fallback` read that filters in memory, which needs every field.
        pub fn toSlice(self: Self, allocator: std.mem.Allocator) ![]Output {
            const p = self.plan();
            if (comptime !projected) return self.readTuples(p, allocator);
            if (comptime supported.projection) {
                if (!p.in_memory) {
                    const span = self.instrument(.read, &p.pushed);
                    return span.end(self.dataset.readProjected(p.pushed, Output, allocator));
                }
            }
            const rows = try self.readTuples(p, allocator);
            errdefer freeTuples(allocator, rows);
            const out = try mapper.Mapper(Tuple, Output, .{}).many(allocator, rows);
            // The selected strings moved to `out`; the others are dropped.
            if (comptime caller_owns) {
                for (rows) |row| strings.freeFields(Tuple, allocator, row, comptime strings.fieldNames(Output));
            }
            allocator.free(rows);
            return out;
        }

        /// ROM's `relation.one`: null when empty, error when ambiguous.
        /// Free the tuple with `freeOne(allocator, tuple)`.
        pub fn one(self: Self, allocator: std.mem.Allocator) !?Output {
            const rows = try self.limit(2).toSlice(allocator);
            if (rows.len > 1) {
                self.free(allocator, rows);
                return error.MoreThanOneTuple;
            }
            defer allocator.free(rows);
            return if (rows.len == 1) rows[0] else null;
        }

        /// Free the tuple with `freeOne(allocator, tuple)`.
        pub fn first(self: Self, allocator: std.mem.Allocator) !?Output {
            const rows = try self.limit(1).toSlice(allocator);
            defer allocator.free(rows);
            return if (rows.len == 1) rows[0] else null;
        }

        /// Frees what `toSlice` returned, with the allocator given to it:
        /// the slice, and the strings in it when the dataset's strings are
        /// caller-owned. Correct on every adapter, so code that should run
        /// on memory and Postgres alike frees reads with it.
        pub fn free(self: Self, allocator: std.mem.Allocator, rows: []const Output) void {
            _ = self;
            freeRows(allocator, rows);
        }

        /// `free` without a relation value, for types built on one (such as
        /// a `paginate` result).
        pub fn freeRows(allocator: std.mem.Allocator, rows: []const Output) void {
            if (comptime caller_owns) strings.freeAll(Output, allocator, rows) else allocator.free(rows);
        }

        /// Frees the strings of a tuple from `one`, `first` or
        /// `create(...).commitAlloc(allocator)`, when they are
        /// caller-owned. Does nothing for a `.dataset` adapter.
        pub fn freeOne(self: Self, allocator: std.mem.Allocator, row: Output) void {
            _ = self;
            if (comptime caller_owns) strings.freeFields(Output, allocator, row, &.{});
        }

        fn freeTuples(allocator: std.mem.Allocator, rows: []const Tuple) void {
            if (comptime caller_owns) strings.freeAll(Tuple, allocator, rows) else allocator.free(rows);
        }

        fn dropStrings(allocator: std.mem.Allocator, row: Tuple) void {
            strings.freeFields(Tuple, allocator, row, &.{});
        }

        /// The number of tuples `toSlice` would return. A `.fallback`
        /// relation's `count` takes an allocator, because when part of the
        /// query runs in memory it has to read the rows to count them.
        pub const count = if (mode == .strict) countStrict else countFallback;

        fn countStrict(self: Self) !usize {
            const span = self.instrument(.count, &self.query);
            return try span.end(self.dataset.count(self.query));
        }

        fn countFallback(self: Self, allocator: std.mem.Allocator) !usize {
            const p = self.plan();
            if (!p.in_memory) {
                const span = self.instrument(.count, &p.pushed);
                return try span.end(self.dataset.count(p.pushed));
            }
            const rows = try self.readTuples(p, allocator);
            defer freeTuples(allocator, rows);
            return rows.len;
        }

        /// ROM's `relation.map_to(Entity)` / auto_struct: copy matching
        /// attributes by name into `E`. After `select`, only the selected
        /// attributes are there to copy.
        pub fn mapTo(self: Self, comptime E: type, allocator: std.mem.Allocator) ![]E {
            return self.mapWith(mapper.Mapper(Output, E, .{}), allocator);
        }

        /// ROM's `relation.map_with(:mapper)`. `M.Input` is `Output`.
        ///
        /// With caller-owned strings, the strings the mapper copies into
        /// the entities move there (free them yourself, or read into an
        /// arena), and the others are freed here. A mapper that copies one
        /// string attribute into two fields gives two owners of one string.
        pub fn mapWith(self: Self, comptime M: type, allocator: std.mem.Allocator) ![]M.Output {
            const rows = try self.toSlice(allocator);
            errdefer self.free(allocator, rows);
            const out = try M.many(allocator, rows);
            if (comptime caller_owns) {
                for (rows) |row| strings.freeFields(Output, allocator, row, M.sources);
            }
            allocator.free(rows);
            return out;
        }

        // -- associations --------------------------------------------------

        /// ROM's `users.combine(:posts)`: this relation with the rows of
        /// association `assoc` (declared on its schema), read from `target`,
        /// a relation over the association's target schema, e.g.
        /// `users.combine(.posts, posts.where(.published, .eq, true))`.
        /// Lazy, like any relation; `mapTo(Author, allocator)` reads it with
        /// one `in` query per `Query.max_in` keys. See combine.zig.
        pub fn combine(
            self: Self,
            comptime assoc: @TypeOf(.enum_literal),
            target: anytype,
        ) combine_mod.Combined(Self, S.association(assoc), @TypeOf(target)) {
            return .{ .source = self, .target = target };
        }

        /// ROM's `users.join(:posts)`: the rows of this relation that have
        /// at least one row of association `assoc` (declared on its schema),
        /// each once. Unlike `combine`, the join filters the parents in the
        /// dataset and reads only their own columns, so the result is a
        /// relation of the same type, and filters, order, paging, `select`
        /// and `combine` all still apply. Narrow the joined rows with
        /// `whereJoined`.
        ///
        /// Needs `supports.join`; without it this is a compile error, even
        /// on a `.fallback` relation, because a join reads another dataset
        /// and can't run in memory on this one's rows. A query has at most
        /// one join: joining the same association again changes nothing,
        /// and joining a second one panics. `update` and `delete` on a
        /// joined relation return `error.JoinedWrite`.
        pub fn join(self: Self, comptime assoc: @TypeOf(.enum_literal)) Self {
            const a = comptime S.association(assoc);
            comptime requireJoin(a, "join(." ++ a.name ++ ")");
            if (self.query.join) |j| {
                if (std.mem.eql(u8, j.assoc, a.name)) return self;
                std.debug.panic("zom: relation '{s}' already joins '{s}'; a query has at most one join, so it can't join '{s}' too", .{
                    S.name, j.assoc, a.name,
                });
            }
            var next = self;
            next.query.join = .{
                .assoc = a.name,
                .table = a.target.name,
                .source_key = if (a.kind == .has_many) a.primary_key else a.foreign_key,
                .target_key = if (a.kind == .has_many) a.foreign_key else a.primary_key,
            };
            return next;
        }

        /// A filter on the joined rows of a relation joined with
        /// `join(assoc)`, typed and checked like `where` on the target's
        /// tuple: `users.join(.posts).whereJoined(.posts, .published, .eq,
        /// true)` is the users with at least one published post. Several
        /// are AND-ed, and must all hold for the same joined row. At most
        /// `zom.Join.max_filters`; past that, panics. Panics when the
        /// relation is not joined with `assoc`.
        pub fn whereJoined(
            self: Self,
            comptime assoc: @TypeOf(.enum_literal),
            comptime field: std.meta.FieldEnum(S.association(assoc).target.Tuple),
            comptime op: q.Op,
            value: anytype,
        ) Self {
            const a = comptime S.association(assoc);
            const call = "whereJoined(." ++ a.name ++ ", ." ++ @tagName(field) ++ ", ." ++ @tagName(op) ++ ", ...)";
            comptime requireJoin(a, call);
            if (comptime Adapter.filterGap(a.target, @tagName(field), op)) |why|
                @compileError("zom: adapter '" ++ Adapter.name ++ "' cannot evaluate `" ++ call ++ "` on relation '" ++
                    S.name ++ "': on the joined dataset '" ++ a.target.name ++ "', " ++ why);
            const j = self.query.join orelse
                std.debug.panic("zom: relation '{s}': " ++ call ++ " needs join(.{s}) first", .{ S.name, a.name });
            if (!std.mem.eql(u8, j.assoc, a.name))
                std.debug.panic("zom: relation '{s}' joins '{s}', not '{s}'; " ++ call ++ " needs join(.{s})", .{
                    S.name, j.assoc, a.name, a.name,
                });
            var next = self;
            next.query.join = j.where(a.target.Tuple, field, op, value);
            return next;
        }

        /// Joins never fall back to memory, so this is checked in either mode.
        fn requireJoin(comptime a: @import("schema.zig").Association, comptime call: []const u8) void {
            if (!supported.join)
                @compileError("zom: adapter '" ++ Adapter.name ++ "' cannot evaluate `" ++ call ++ "` on relation '" ++
                    S.name ++ "': `supports.join` is false, and a join reads another dataset ('" ++ a.target.name ++
                    "'), so `allowFallback()` can't run it in memory; use `combine(." ++ a.name ++ ", ...)` to load the associated rows instead");
        }

        // -- commands / changesets ----------------------------------------
        //
        // `update` and `delete` target the query, so they work after
        // `select` too. `create` and `createMany` take whole tuples, which a
        // projected relation does not describe, so they are refused there.
        // On a `.fallback` relation, `update` and `delete` only run when the
        // dataset can evaluate every filter (see `writeQuery`).

        /// ROM's `users.changeset(:create, data)`.
        pub fn create(self: Self, tuple: Tuple) changeset.Create(Self) {
            comptime requireWhole("create");
            comptime Adapter.require(S, .writable, "create");
            return .{ .relation = self, .tuple = tuple };
        }

        /// ROM's `users.changeset(:create, [data, ...])`. Uses the dataset's
        /// `insertMany` when it has one, else loops over `insert`; see
        /// `changeset.CreateMany` for what a failure leaves behind. The
        /// changeset borrows `tuples` until `commit`.
        pub fn createMany(self: Self, tuples: []const Tuple) changeset.CreateMany(Self) {
            comptime requireWhole("createMany");
            comptime Adapter.requireAny(S, &.{ .batch_insert, .writable }, "createMany");
            return .{ .relation = self, .tuples = tuples };
        }

        /// ROM's `posts.changeset(:create, data).associate(user)`, parent
        /// first: `posts.associate(.author, user).create(.{ ... })` sets the
        /// foreign key of the `belongsTo` association `assoc` from `parent`
        /// (the target's tuple, or a `select` of it that kept the key), and
        /// its `create` / `createMany` take the tuple without that key. See
        /// changeset.zig for why the parent comes first.
        pub fn associate(
            self: Self,
            comptime assoc: @TypeOf(.enum_literal),
            parent: anytype,
        ) changeset.Scoped(Self, changeset.withKey(Self, .{}, assoc, @TypeOf(parent))) {
            comptime requireWhole("associate");
            return (changeset.Scoped(Self, .{}){ .relation = self }).associate(assoc, parent);
        }

        /// ROM's `users.by_pk(1).changeset(:update, data)`, built with `.set`.
        pub fn update(self: Self) changeset.Update(Self) {
            comptime Adapter.require(S, .updatable, "update");
            return .{ .relation = self };
        }

        /// ROM's `users.by_pk(1).command(:delete).call`.
        pub fn delete(self: Self) !usize {
            comptime Adapter.require(S, .deletable, "delete");
            const query = try self.writeQuery();
            const span = self.instrument(.delete, &query);
            return try span.end(self.dataset.delete(query));
        }

        /// Starts the instrumentation span of one dataset call, calling the
        /// schema's `before` hooks; `span.end(result)` calls the `after`
        /// ones. Zero-size and free without an instrumentation plugin. For
        /// changesets: see plugins.zig.
        pub inline fn instrument(self: *const Self, comptime op: plugins.instrumentation.Op, query: ?*const Q) plugins.Span(S) {
            return plugins.begin(S, Adapter.name, op, query, &self.plugin_context);
        }

        fn requireWhole(comptime method: []const u8) void {
            if (projected)
                @compileError("zom: `" ++ method ++ "` needs whole tuples, but relation '" ++ S.name ++
                    "' is projected by `select`; call it on the relation before `select`");
        }
    };
}
