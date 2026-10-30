//! Relation = ROM's `ROM::Relation`.
//!
//! A relation is a cheap, immutable value: a pointer to an adapter dataset
//! plus a query. Every chained call (`where`, `order`, `limit`) returns a new
//! relation, exactly like `users.where(...).order(...)` in ROM. Nothing hits
//! the dataset until you materialize it (`toSlice`, `one`, `mapTo`, ...).
//!
//! The adapter contract is checked at compile time by `zom.Adapter` (see
//! adapter.zig). `create`, `update` and `delete` need the matching dataset
//! capability, and fail to compile, naming the adapter, when it is missing.

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

        pub fn where(self: Self, comptime field: Field, op: q.Op, value: anytype) Self {
            const F = @FieldType(Tuple, @tagName(field));
            comptime q.assertAssignable(F, @TypeOf(value), @tagName(field));
            if (comptime q.isComptimeOnly(@TypeOf(value))) comptime q.assertLiteral(F, value, @tagName(field));
            var next = self;
            next.query.addFilter(.{ .field = field, .op = op, .value = q.toValue(value) });
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
            return .{ .relation = self, .tuple = tuple };
        }

        /// ROM's `users.by_pk(1).changeset(:update, data)`, built with `.set`.
        pub fn update(self: Self) changeset.Update(Self) {
            return .{ .relation = self };
        }

        /// ROM's `users.by_pk(1).command(:delete).call`.
        pub fn delete(self: Self) !usize {
            comptime Adapter.require(S, .deletable, "delete");
            return try self.dataset.delete(self.query);
        }
    };
}
