// expect: zom.hasMany: association 'notes' of schema "balances": this schema has no primary key (it is a view), so it has no key for the target's rows to point at; declare the association on the other side instead
const zom = @import("zom");

const Balance = struct { account_id: u32, timestamp: u64, amount: i64 };
const Note = struct { id: u32, timestamp: u64 };
const BalanceSchema = zom.Schema(Balance, "balances", null, .{
    .associations = struct {
        pub const notes = zom.hasMany(NoteSchema, .timestamp);
    },
});
const NoteSchema = zom.Schema(Note, "notes", .id, .{});

export fn entry() void {
    _ = BalanceSchema;
}
