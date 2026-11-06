// expect: zom: adapter 'tigerbeetle' cannot evaluate `where(.ledger, .lt, ...)` on relation 'accounts': its dataset's `filterable` rejects `.lt` on 'ledger'; call `allowFallback()`
//! `ledger` is filtered by equality only: an unsupported op on a field
//! that has supported ones.
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
    _ = accounts.where(.ledger, .eq, 700).where(.ledger, .lt, 800);
}
