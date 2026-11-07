// expect: zom.Schema("balances") has no primary key (it was declared with `null`, as a view), so nothing that needs one (such as `byPk`) can be used on it; filter with `where` instead
const zom = @import("zom");

const Balance = struct { account_id: u32, timestamp: u64, amount: i64 };
const BalanceSchema = zom.Schema(Balance, "balances", null, .{});

export fn entry() void {
    _ = BalanceSchema.primary_key;
}
