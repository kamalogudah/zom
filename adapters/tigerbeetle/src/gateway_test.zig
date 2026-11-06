//! The gateway against the adapter contract. These need no server; the
//! test that talks to one is in gateway.zig.

const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("root.zig");

const testing = std.testing;
const Gateway = zom_tigerbeetle.Gateway;
const A = zom.Adapter(Gateway);

test "zom.Adapter accepts the gateway" {
    try testing.expectEqualStrings("tigerbeetle", A.name);
}

test "records are immutable: insert and insertMany, but no update, no delete, no transaction" {
    inline for (.{ zom_tigerbeetle.Account, zom_tigerbeetle.Transfer }) |S| {
        const caps = A.capabilities(S);
        try testing.expect(caps.writable);
        try testing.expect(caps.batch_insert);
        try testing.expect(!caps.updatable);
        try testing.expect(!caps.deletable);
        try testing.expect(!caps.transaction);
        // `relation.update()` on them is a compile error:
        // adapters/tigerbeetle/tests/compile_errors/update_transfers.zig.
    }
}

test "each dataset has its own result codes and errors" {
    const Accounts = Gateway.Dataset(zom_tigerbeetle.Account);
    const Transfers = Gateway.Dataset(zom_tigerbeetle.Transfer);
    try testing.expect(Accounts.Code == zom_tigerbeetle.results.CreateAccountResult);
    try testing.expect(Transfers.Code == zom_tigerbeetle.results.CreateTransferResult);
    // The errors callers switch on are in the insert error sets.
    const exceeds: Transfers.InsertError = error.ExceedsCredits;
    const duplicate: Accounts.InsertError = error.DuplicatePrimaryKey;
    try testing.expectEqual(error.ExceedsCredits, exceeds);
    try testing.expectEqual(error.DuplicatePrimaryKey, duplicate);
}

test "the schemas are the client's structs, keyed by id" {
    try testing.expect(zom_tigerbeetle.Account.Tuple == zom_tigerbeetle.tb.Account);
    try testing.expect(zom_tigerbeetle.Transfer.Tuple == zom_tigerbeetle.tb.Transfer);
    try testing.expectEqual(.id, zom_tigerbeetle.Account.primary_key);
    try testing.expectEqualStrings("accounts", zom_tigerbeetle.Account.name);
    try testing.expectEqualStrings("transfers", zom_tigerbeetle.Transfer.name);
}

test "every field of the records works in a query" {
    // u128 ids and amounts, u64 timestamps, u16 flags and the u32 reserved
    // field all become zom.Values.
    const Q = zom.Query(zom_tigerbeetle.tb.Account);
    const max = std.math.maxInt(u128);
    const query = (Q{}).where(.id, .eq, max).where(.flags, .eq, 0b1000).where(.reserved, .eq, 0).where(.ledger, .eq, 700);
    try testing.expectEqual(4, query.filterSlice().len);
}

test "Dataset takes any schema of tb.Account or tb.Transfer keyed by id" {
    // Any other tuple type, or another primary key, is a compile error
    // (checkSchema in gateway.zig), which a test can't run.
    _ = Gateway.Dataset(zom_tigerbeetle.Account);
    _ = Gateway.Dataset(zom.Schema(zom_tigerbeetle.tb.Transfer, "my_transfers", .id, .{}));
}

test "init rejects an address that doesn't parse" {
    try testing.expectError(error.InvalidAddress, Gateway.init(testing.allocator, .{
        .io = testing.io,
        .cluster_id = 0,
        .addresses = "not an address",
    }));
}
