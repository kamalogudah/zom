// expect: zom: adapter 'tigerbeetle' is read-only for relation 'account_balances': `create` needs the `writable` capability (dataset has no `insert`)
//! Balances are a read-only view of `get_account_balances`: TigerBeetle
//! writes them as transfers post.
const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("zom_tigerbeetle");

export fn entry() void {
    var gateway = zom_tigerbeetle.Gateway.init(std.heap.page_allocator, .{
        .io = undefined,
        .cluster_id = 0,
        .addresses = "3000",
    }) catch return;
    const balances = zom.Relation(zom_tigerbeetle.AccountBalance, zom_tigerbeetle.Gateway).init(&gateway) catch return;
    _ = balances.create(.{ .account_id = 1, .timestamp = 1 }).commit() catch return;
}
