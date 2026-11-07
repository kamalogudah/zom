// expect: zom: byPk on relation 'account_balances', whose schema has no primary key (it is a view); filter with `where` instead
//! A balance row is unique per (account_id, timestamp): a transfer moves
//! both its accounts' balances, so `timestamp` alone is no key.
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
    _ = balances.byPk(@as(u64, 1));
}
