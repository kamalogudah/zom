//! Changesets = ROM's `ROM::Changeset`.
//!
//! A changeset holds the data for one write plus the relation it targets,
//! and only touches the dataset on `commit`. `Create.map` plays the role of
//! ROM's `map { ... }` transformation pipeline.
//!
//! `Relation.create`, `createMany` and `update` check the adapter's capabilities;
//! `commit` checks them again for a changeset built by hand.

const std = @import("std");
const q = @import("query.zig");

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

        /// Returns the tuple as stored by the adapter.
        pub fn commit(self: Self) !Rel.Tuple {
            comptime Rel.Adapter.require(Rel.schema, .writable, "create");
            return self.relation.dataset.insert(self.tuple);
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
    return struct {
        const Self = @This();

        relation: Rel,
        tuples: []const Rel.Tuple,

        /// Returns the number of tuples inserted.
        pub fn commit(self: Self) !usize {
            comptime Rel.Adapter.requireAny(Rel.schema, &.{ .batch_insert, .writable }, "createMany");
            if (self.tuples.len == 0) return 0;
            if (comptime Rel.Adapter.has(Rel.schema, .batch_insert))
                return self.relation.dataset.insertMany(self.tuples);
            for (self.tuples) |t| _ = try self.relation.dataset.insert(t);
            return self.tuples.len;
        }
    };
}

pub fn Update(comptime Rel: type) type {
    return struct {
        const Self = @This();
        pub const max_changes = 16;

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

        /// Returns the number of tuples updated.
        pub fn commit(self: Self) !usize {
            comptime Rel.Adapter.require(Rel.schema, .updatable, "update");
            if (self.change_count == 0) return 0;
            return self.relation.dataset.update(self.relation.query, self.changes[0..self.change_count]);
        }
    };
}
