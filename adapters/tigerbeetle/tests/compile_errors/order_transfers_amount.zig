// expect: zom: adapter 'tigerbeetle' cannot evaluate `order(.amount, ...)` on relation 'transfers': its dataset's `orderable` rejects ordering by 'amount'; call `allowFallback()`
//! `query_transfers` returns rows by timestamp only.
const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("zom_tigerbeetle");

const Transfers = zom.Relation(zom_tigerbeetle.Transfer, zom_tigerbeetle.Gateway);

export fn entry() void {
    var gateway = zom_tigerbeetle.Gateway.init(std.heap.page_allocator, .{
        .io = undefined,
        .cluster_id = 0,
        .addresses = "3000",
    }) catch return;
    const transfers = Transfers.init(&gateway) catch return;
    _ = transfers.order(.timestamp, .desc).order(.amount, .desc);
}
