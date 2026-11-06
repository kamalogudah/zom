// expect: zom: adapter 'tigerbeetle' does not support `update` for relation 'transfers': `update` needs the `updatable` capability (dataset has no `update`)
//! TigerBeetle records are immutable: a transfer is corrected with another
//! transfer, never updated.
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
    _ = transfers.where(.id, .eq, 1).update();
}
