// expect: zom: adapter 'tigerbeetle' does not support `delete` for relation 'accounts': `delete` needs the `deletable` capability (dataset has no `delete`)
//! TigerBeetle records are immutable: an account is closed (`flags.closed`),
//! never deleted.
const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("zom_tigerbeetle");

const Accounts = zom.Relation(zom_tigerbeetle.Account, zom_tigerbeetle.Gateway);

export fn entry() void {
    var gateway = zom_tigerbeetle.Gateway.init(std.heap.page_allocator, .{
        .io = undefined,
        .cluster_id = 0,
        .addresses = "3000",
    }) catch return;
    const accounts = Accounts.init(&gateway) catch return;
    _ = accounts.where(.id, .eq, 1).delete() catch return;
}
