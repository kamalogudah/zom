// expect: zom: adapter 'tigerbeetle' cannot evaluate `where(.amount, .gt, ...)` on relation 'transfers': its dataset's `filterable` rejects `.gt` on 'amount'; call `allowFallback()`
//! `query_transfers` has no index on `amount`: an unsupported field.
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
    _ = transfers.where(.ledger, .eq, 700).where(.amount, .gt, 100);
}
