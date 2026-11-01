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

const std = @import("std");
const q = @import("query.zig");
const mapper = @import("mapper.zig");
const changeset = @import("changeset.zig");
const adapter = @import("adapter.zig");
const projection = @import("projection.zig");

/// A relation over schema `S`, reading whole tuples.
pub fn Relation(comptime S: type, comptime Gateway: type) type {
    return RelationOf(S, Gateway, S.Tuple);
}

/// A relation over schema `S` whose reads return `Out`: `S.Tuple`, or a
/// `zom.Project(S.Tuple, ...)` after `select`. `Relation(S, G)` is
/// `RelationOf(S, G, S.Tuple)`, the same type.
pub fn RelationOf(comptime S: type, comptime Gateway: type, comptime Out: type) type {
    return struct {
        const Self = @This();

        pub const schema = S;
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

        dataset: *DatasetT,
        query: Q = .{},

        pub fn init(gateway: *Gateway) !Self {
            return .{ .dataset = try gateway.dataset(S) };
        }

        // -- query building (returns new relations) ------------------------

        /// See `Query.where` for what each op takes, e.g.
        /// `where(.id, .in, .{ 1, 2, 3 })`, `where(.name, .like, "Ach%")`,
        /// `where(.age, .between, .{ 18, 30 })`, `where(.age, .is_null, {})`.
        pub fn where(self: Self, comptime field: Field, comptime op: q.Op, value: anytype) Self {
            var next = self;
            next.query = self.query.where(field, op, value);
            return next;
        }

        /// `where(field, .in, ...)` for a runtime slice, at most
        /// `Q.max_in` long. The relation borrows `values` without copying,
        /// so it (and every relation chained from it) is invalid once that
        /// slice is freed or changed.
        pub fn whereIn(self: Self, comptime field: Field, values: anytype) Self {
            var next = self;
            next.query = self.query.whereIn(field, values);
            return next;
        }

        /// `whereIn` for `not_in`, with the same borrowing rule.
        pub fn whereNotIn(self: Self, comptime field: Field, values: anytype) Self {
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
            return next;
        }

        /// AND NOT `cond`, e.g. `whereNot(.{ .age, .gt, 30 })`. Rows where
        /// `cond` is unknown (a null attribute) match neither `cond` nor its
        /// negation, as in SQL. See `Query.whereNot`.
        pub fn whereNot(self: Self, cond: anytype) Self {
            var next = self;
            next.query = self.query.whereNot(cond);
            return next;
        }

        pub fn byPk(self: Self, value: anytype) Self {
            return self.where(S.primary_key, .eq, value);
        }

        /// Adds a sort key after the ones already set: `.order(.a, .asc)
        /// .order(.b, .desc)` is `ORDER BY a ASC, b DESC`. At most
        /// `Query.max_orders` keys; past that, panics.
        pub fn order(self: Self, comptime field: Field, direction: q.Direction) Self {
            var next = self;
            next.query = self.query.order(field, direction);
            return next;
        }

        /// Replaces every sort key: `reorder(.{ .{ .role, .asc }, .{ .age,
        /// .desc } })`, or `reorder(.{})` for none. See `Query.reorder`.
        pub fn reorder(self: Self, keys: anytype) Self {
            var next = self;
            next.query = self.query.reorder(keys);
            return next;
        }

        pub fn limit(self: Self, n: usize) Self {
            var next = self;
            next.query.limit = n;
            return next;
        }

        pub fn offset(self: Self, n: usize) Self {
            var next = self;
            next.query.offset = n;
            return next;
        }

        /// ROM's `select(:id, :name)`: the same relation, reading only
        /// `fields`, a tuple of attribute names such as `.{ .id, .name }`.
        /// Reads return `zom.Project(Tuple, fields)`, which has only those
        /// fields, in that order. Filters and orders, before or after, may
        /// still use any attribute. On a relation that is already projected,
        /// `fields` must be among the ones selected. The primary key does
        /// not have to be selected.
        pub fn select(self: Self, comptime fields: anytype) Selected(fields) {
            return .{ .dataset = self.dataset, .query = self.query };
        }

        fn Selected(comptime fields: anytype) type {
            const P = projection.Project(Tuple, fields);
            if (projected) {
                for (@typeInfo(P).@"struct".fields) |f| {
                    if (!@hasField(Output, f.name))
                        @compileError("zom.select: '" ++ f.name ++ "' was not selected on this relation, so it cannot be selected again");
                }
            }
            return RelationOf(S, Gateway, P);
        }

        // -- materializing -------------------------------------------------

        /// Caller owns the returned slice. String attributes point into the
        /// dataset and stay valid as long as the gateway lives.
        ///
        /// After `select`, a dataset with `supports.projection` reads the
        /// selected attributes itself (`readProjected`); any other dataset
        /// reads whole tuples, which zom maps down and frees.
        pub fn toSlice(self: Self, allocator: std.mem.Allocator) ![]Output {
            if (comptime !projected) return self.dataset.read(self.query, allocator);
            if (comptime Adapter.supports(S).projection)
                return self.dataset.readProjected(self.query, Output, allocator);
            const rows = try self.dataset.read(self.query, allocator);
            defer allocator.free(rows);
            return mapper.Mapper(Tuple, Output, .{}).many(allocator, rows);
        }

        /// ROM's `relation.one`: null when empty, error when ambiguous.
        pub fn one(self: Self, allocator: std.mem.Allocator) !?Output {
            const rows = try self.limit(2).toSlice(allocator);
            defer allocator.free(rows);
            if (rows.len > 1) return error.MoreThanOneTuple;
            return if (rows.len == 1) rows[0] else null;
        }

        pub fn first(self: Self, allocator: std.mem.Allocator) !?Output {
            const rows = try self.limit(1).toSlice(allocator);
            defer allocator.free(rows);
            return if (rows.len == 1) rows[0] else null;
        }

        pub fn count(self: Self) !usize {
            return try self.dataset.count(self.query);
        }

        /// ROM's `relation.map_to(Entity)` / auto_struct: copy matching
        /// attributes by name into `E`. After `select`, only the selected
        /// attributes are there to copy.
        pub fn mapTo(self: Self, comptime E: type, allocator: std.mem.Allocator) ![]E {
            return self.mapWith(mapper.Mapper(Output, E, .{}), allocator);
        }

        /// ROM's `relation.map_with(:mapper)`. `M.Input` is `Output`.
        pub fn mapWith(self: Self, comptime M: type, allocator: std.mem.Allocator) ![]M.Output {
            const rows = try self.toSlice(allocator);
            defer allocator.free(rows);
            return M.many(allocator, rows);
        }

        // -- commands / changesets ----------------------------------------
        //
        // `update` and `delete` target the query, so they work after
        // `select` too. `create` and `createMany` take whole tuples, which a
        // projected relation does not describe, so they are refused there.

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

        /// ROM's `users.by_pk(1).changeset(:update, data)`, built with `.set`.
        pub fn update(self: Self) changeset.Update(Self) {
            comptime Adapter.require(S, .updatable, "update");
            return .{ .relation = self };
        }

        /// ROM's `users.by_pk(1).command(:delete).call`.
        pub fn delete(self: Self) !usize {
            comptime Adapter.require(S, .deletable, "delete");
            return try self.dataset.delete(self.query);
        }

        fn requireWhole(comptime method: []const u8) void {
            if (projected)
                @compileError("zom: `" ++ method ++ "` needs whole tuples, but relation '" ++ S.name ++
                    "' is projected by `select`; call it on the relation before `select`");
        }
    };
}
