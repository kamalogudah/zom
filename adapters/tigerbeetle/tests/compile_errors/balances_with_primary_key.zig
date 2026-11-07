// expect: zom-tigerbeetle: schema "my_balances" is a view of balances and must be declared without a primary key (`null`), found `.timestamp`
//! Keying your own balance schema by `timestamp` would claim a uniqueness
//! it doesn't have.
const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("zom_tigerbeetle");

const MyBalances = zom.Schema(zom_tigerbeetle.tb.AccountBalance, "my_balances", .timestamp, .{});

export fn entry() void {
    var gateway = zom_tigerbeetle.Gateway.init(std.heap.page_allocator, .{
        .io = undefined,
        .cluster_id = 0,
        .addresses = "3000",
    }) catch return;
    const balances = zom.Relation(MyBalances, zom_tigerbeetle.Gateway).init(&gateway) catch return;
    _ = balances.where(.account_id, .eq, 1).toSlice(std.heap.page_allocator) catch return;
}
