// expect: zom: byPk on relation 'balances', whose schema has no primary key (it is a view); filter with `where` instead
const zom = @import("zom");

const Balance = struct { account_id: u32, timestamp: u64, amount: i64 };
const BalanceSchema = zom.Schema(Balance, "balances", null, .{});
const Balances = zom.Relation(BalanceSchema, zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const balances = Balances.init(&gw) catch return;
    _ = balances.byPk(@as(u64, 1));
}
