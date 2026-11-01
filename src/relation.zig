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

const std = @import("std");
const q = @import("query.zig");
const mapper = @import("mapper.zig");
const changeset = @import("changeset.zig");
const adapter = @import("adapter.zig");

pub fn Relation(comptime S: type, comptime Gateway: type) type {
    return struct {
        const Self = @This();

        pub const schema = S;
        pub const Tuple = S.Tuple;
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

        pub fn order(self: Self, comptime field: Field, direction: q.Direction) Self {
            var next = self;
            next.query.order = .{ .field = field, .direction = direction };
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

        // -- materializing -------------------------------------------------

        /// Caller owns the returned slice. String attributes point into the
        /// dataset and stay valid as long as the gateway lives.
        pub fn toSlice(self: Self, allocator: std.mem.Allocator) ![]Tuple {
            return self.dataset.read(self.query, allocator);
        }

        /// ROM's `relation.one`: null when empty, error when ambiguous.
        pub fn one(self: Self, allocator: std.mem.Allocator) !?Tuple {
            const rows = try self.limit(2).toSlice(allocator);
            defer allocator.free(rows);
            if (rows.len > 1) return error.MoreThanOneTuple;
            return if (rows.len == 1) rows[0] else null;
        }

        pub fn first(self: Self, allocator: std.mem.Allocator) !?Tuple {
            const rows = try self.limit(1).toSlice(allocator);
            defer allocator.free(rows);
            return if (rows.len == 1) rows[0] else null;
        }

        pub fn count(self: Self) !usize {
            return try self.dataset.count(self.query);
        }

        /// ROM's `relation.map_to(Entity)` / auto_struct: copy matching
        /// attributes by name into `E`.
        pub fn mapTo(self: Self, comptime E: type, allocator: std.mem.Allocator) ![]E {
            return self.mapWith(mapper.Mapper(Tuple, E, .{}), allocator);
        }

        /// ROM's `relation.map_with(:mapper)`.
        pub fn mapWith(self: Self, comptime M: type, allocator: std.mem.Allocator) ![]M.Output {
            const rows = try self.toSlice(allocator);
            defer allocator.free(rows);
            return M.many(allocator, rows);
        }

        // -- commands / changesets ----------------------------------------

        /// ROM's `users.changeset(:create, data)`.
        pub fn create(self: Self, tuple: Tuple) changeset.Create(Self) {
            comptime Adapter.require(S, .writable, "create");
            return .{ .relation = self, .tuple = tuple };
        }

        /// ROM's `users.changeset(:create, [data, ...])`. Uses the dataset's
        /// `insertMany` when it has one, else loops over `insert`; see
        /// `changeset.CreateMany` for what a failure leaves behind. The
        /// changeset borrows `tuples` until `commit`.
        pub fn createMany(self: Self, tuples: []const Tuple) changeset.CreateMany(Self) {
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
    };
}
