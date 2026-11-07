// expect: zom.belongsTo: association 'balance' of schema "notes": the target, schema "balances", has no primary key (it is a view), so nothing can belong to it
const zom = @import("zom");

const Balance = struct { account_id: u32, timestamp: u64, amount: i64 };
const Note = struct { id: u32, timestamp: u64 };
const BalanceSchema = zom.Schema(Balance, "balances", null, .{});
const NoteSchema = zom.Schema(Note, "notes", .id, .{
    .associations = struct {
        pub const balance = zom.belongsTo(BalanceSchema, .timestamp);
    },
});

export fn entry() void {
    _ = NoteSchema;
}
