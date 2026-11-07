//! Linked event chains: TigerBeetle's all-or-nothing writes, as a changeset.
//!
//! TigerBeetle has no transactions. Its atomicity is a chain of events in
//! one request, `flags.linked` set on every event but the last: if one
//! fails, none is applied. `relation.linked()` builds such a chain:
//!
//!     _ = try transfers.linked()
//!         .add(.{ .id = 1, .debit_account_id = a, .credit_account_id = b, .amount = 100, .ledger = 700, .code = 1 })
//!         .add(.{ .id = 2, .debit_account_id = b, .credit_account_id = c, .amount = 100, .ledger = 700, .code = 1 })
//!         .commit(); // both, or neither
//!
//! The events are given without `flags.linked`; `commit` sets it on a copy
//! of each event but the last, clears it on the last, and leaves every
//! other flag (`pending`, `history`, ...) as it was. The chain goes in one
//! request, so it can't be longer than the cluster's batch limit
//! (`error.LinkedChainTooLong`, nothing sent).
//!
//! When the chain fails, every event but the one at fault gets
//! `linked_event_failed`; `commit` returns the cause's own error
//! (`error.ExceedsCredits`, `error.DebitAccountNotFound`, ...), and
//! `reportTo(&failure)` says which event it was:
//!
//!     var failure: Transfers.Linked().Failure = undefined;
//!     _ = transfers.linked().add(t1).add(t2).reportTo(&failure).commit() catch |err| {
//!         // failure.index == 1, failure.code == .exceeds_credits
//!     };
//!
//! A chain has a fixed capacity (`linked_capacity` events, kept in the changeset
//! value, like `Update.changes`): adding past it is a bug, and asserts.
//! `container.transaction(.tb, ...)` doesn't compile, and its message points
//! here.

const std = @import("std");
const zom = @import("zom");
const tb = @import("tb.zig");

/// The most events one `linked()` chain holds.
pub const linked_capacity = 32;

/// What `relation.linked()` returns for a relation over `tb.Account` or
/// `tb.Transfer`.
pub fn LinkedChangeset(comptime Rel: type) type {
    const T = Rel.Tuple;
    const Flags = if (T == tb.Account) tb.AccountFlags else tb.TransferFlags;
    const D = Rel.DatasetT;
    return struct {
        const Self = @This();

        pub const capacity = linked_capacity;
        /// Which event made the chain fail, and its result code.
        pub const Failure = D.ChainFailure;

        relation: Rel,
        events: [capacity]T = undefined,
        len: usize = 0,
        failure: ?*Failure = null,

        /// The chain with `event` added at the end.
        pub fn add(self: Self, event: T) Self {
            std.debug.assert(self.len < capacity);
            var next = self;
            next.events[next.len] = event;
            next.len += 1;
            return next;
        }

        /// The chain, telling `failure` which event made `commit` fail.
        /// `failure` is only written on a failed chain.
        pub fn reportTo(self: Self, failure: *Failure) Self {
            var next = self;
            next.failure = failure;
            return next;
        }

        /// The events as `commit` sends them, in `out`: `flags.linked` on
        /// every event but the last, the other flags as given. Before the
        /// schema's `beforeCreate` hooks, which `commit` runs first.
        pub fn prepared(self: *const Self, out: *[capacity]T) []const T {
            const rows = out[0..self.len];
            @memcpy(rows, self.events[0..self.len]);
            link(rows);
            return rows;
        }

        /// Creates every event or none, in one request. Returns how many
        /// were created: all of them (0 for an empty chain, which sends
        /// nothing). Fails with the dataset's `InsertError` (see
        /// `insertChain` in gateway.zig), or a `beforeCreate` hook's error.
        pub fn commit(self: Self) !usize {
            if (self.len == 0) return 0;
            var batch: [capacity]T = undefined;
            const rows = batch[0..self.len];
            @memcpy(rows, self.events[0..self.len]);
            if (comptime zom.plugins.hasHook(Rel.schema, "beforeCreate")) {
                for (rows) |*row| try zom.plugins.beforeCreate(Rel.schema, row, &self.relation.plugin_context);
            }
            link(rows);
            var reply: [capacity]D.Reply = undefined;
            const span = self.relation.instrument(.insert_many, null);
            return span.end(self.relation.dataset.insertChain(rows, &reply, self.failure));
        }

        fn link(rows: []T) void {
            for (rows, 0..) |*row, i| {
                var flags = Flags.of(row.*);
                flags.linked = i + 1 < rows.len;
                row.flags = Flags.bits(flags);
            }
        }
    };
}

const testing = std.testing;
const Gateway = @import("gateway.zig").Gateway;
const schemas = @import("schemas.zig");

test "commit's batch: linked on every event but the last, the other flags kept" {
    // `prepared` never touches the dataset, so no cluster is needed.
    const Transfers = zom.Relation(schemas.Transfer, Gateway);
    const transfers: Transfers = .{ .dataset = undefined };
    const pending = tb.TransferFlags.bits(.{ .pending = true });
    const chain = transfers.linked()
        .add(.{ .id = 1, .amount = 10, .flags = pending })
        .add(.{ .id = 2, .amount = 20 })
        // Already linked, and last: commit clears it, or the chain is open.
        .add(.{ .id = 3, .amount = 30, .flags = tb.TransferFlags.bits(.{ .linked = true, .closing_debit = true }) });
    var out: [linked_capacity]tb.Transfer = undefined;
    const batch = chain.prepared(&out);
    try testing.expectEqual(3, batch.len);
    const want = [_]tb.TransferFlags{
        .{ .linked = true, .pending = true },
        .{ .linked = true },
        .{ .closing_debit = true },
    };
    for (batch, want, 1..) |row, flags, id| {
        try testing.expectEqual(flags, tb.TransferFlags.of(row));
        try testing.expectEqual(id, row.id);
        try testing.expectEqual(id * 10, row.amount);
    }
    // The changeset's own events are unchanged.
    try testing.expectEqual(pending, chain.events[0].flags);

    // One event is a chain of one: not linked.
    const one = transfers.linked().add(.{ .id = 4, .flags = tb.linked_flag }).prepared(&out);
    try testing.expectEqual(0, one[0].flags);
}

test "accounts chain too, with their own flags" {
    const Accounts = zom.Relation(schemas.Account, Gateway);
    const accounts: Accounts = .{ .dataset = undefined };
    const history = tb.AccountFlags.bits(.{ .history = true });
    var out: [linked_capacity]tb.Account = undefined;
    const batch = accounts.linked().add(.{ .id = 1, .flags = history }).add(.{ .id = 2, .flags = history }).prepared(&out);
    try testing.expectEqual(tb.AccountFlags{ .linked = true, .history = true }, tb.AccountFlags.of(batch[0]));
    try testing.expectEqual(tb.AccountFlags{ .history = true }, tb.AccountFlags.of(batch[1]));
}
