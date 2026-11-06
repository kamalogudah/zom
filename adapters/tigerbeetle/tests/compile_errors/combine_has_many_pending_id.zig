// expect: zom-tigerbeetle: combine(.posted) from "pending_transfers" into "transfers": TigerBeetle can't find rows by 'pending_id'; a hasMany needs debit_account_id, credit_account_id, user_data_128, user_data_64, user_data_32, ledger or code as its foreign key
//! `loadAssociation` picks a TigerBeetle request per association, and no
//! request finds transfers by `pending_id`.
const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("zom_tigerbeetle");

const Pending = zom.Schema(zom_tigerbeetle.tb.Transfer, "pending_transfers", .id, .{
    .associations = struct {
        pub const posted = zom.hasMany(zom_tigerbeetle.Transfer, .pending_id);
    },
});

export fn entry() void {
    var gateway = zom_tigerbeetle.Gateway.init(std.heap.page_allocator, .{
        .io = undefined,
        .cluster_id = 0,
        .addresses = "3000",
    }) catch return;
    const pending = zom.Relation(Pending, zom_tigerbeetle.Gateway).init(&gateway) catch return;
    const transfers = zom.Relation(zom_tigerbeetle.Transfer, zom_tigerbeetle.Gateway).init(&gateway) catch return;
    const Posted = struct { id: u128, posted: []const zom_tigerbeetle.tb.Transfer };
    var result = pending.combine(.posted, transfers).mapTo(Posted, std.heap.page_allocator) catch return;
    result.deinit();
}
