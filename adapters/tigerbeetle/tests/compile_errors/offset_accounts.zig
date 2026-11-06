// expect: zom: adapter 'tigerbeetle' cannot evaluate `offset(...)` on relation 'accounts': `supports.offset` is false; call `allowFallback()`
//! TigerBeetle pages by timestamp; it can't skip rows.
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
    _ = accounts.order(.timestamp, .asc).limit(10).offset(20);
}
