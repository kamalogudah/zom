//! Double-entry bookkeeping on TigerBeetle, through zom only: two accounts
//! on one ledger, a deposit, a linked chain that posts, one that is
//! refused as a whole, then the balances and the customer's history read
//! back. Every call goes through a zom relation or changeset; nothing here
//! talks to the TigerBeetle client directly.
//!
//!   tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development 0_0.tigerbeetle
//!   tigerbeetle start --addresses=3000 --development 0_0.tigerbeetle &
//!   TB_ADDRESSES=3000 zig build run
//!
//! TigerBeetle keeps every record, and ids can't be reused, so each run
//! opens two new accounts with random ids. It prints the same thing every
//! time.

const std = @import("std");
const zom = @import("zom");
const zom_tigerbeetle = @import("zom_tigerbeetle");
const tb = zom_tigerbeetle.tb;

const App = zom.Container(.{
    .gateways = .{ .tb = zom_tigerbeetle.Gateway },
    .relations = .{
        .accounts = .{ zom_tigerbeetle.Account, .tb },
        .transfers = .{ zom_tigerbeetle.Transfer, .tb },
        .balances = .{ zom_tigerbeetle.AccountBalance, .tb },
    },
});
const Transfers = @FieldType(App.Relations, "transfers");

const ledger = 700;
/// Account codes: what kind of account it is (the chart of accounts).
const code_bank = 1;
const code_customer = 2;
/// Transfer codes: why the money moved.
const code_deposit = 10;
const code_purchase = 11;
const code_fee = 12;
const code_withdrawal = 13;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // An arena for every row read: freed once, when `main` returns.
    const arena = init.arena.allocator();

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    var app: App = undefined;
    try app.init(init.gpa, .{ .tb = .{ .io = io, .cluster_id = 0, .addresses = try addresses(init) } });
    defer app.deinit();
    const r = app.relations;

    // Ids no earlier run used: high 64 bits random, low bits a sequence.
    var seed: [8]u8 = undefined;
    io.random(&seed);
    var next_id: u128 = @as(u128, std.mem.readInt(u64, &seed, .little)) << 64;

    // Two accounts, opened together. The customer can't spend more than it
    // was credited, and keeps its balance history.
    const bank = takeId(&next_id);
    const customer = takeId(&next_id);
    _ = try r.accounts.linked()
        .add(.{ .id = bank, .ledger = ledger, .code = code_bank })
        .add(.{
            .id = customer,
            .ledger = ledger,
            .code = code_customer,
            .flags = tb.AccountFlags.bits(.{ .debits_must_not_exceed_credits = true, .history = true }),
        })
        .commit();
    try out.print("opened: bank, customer (ledger {d})\n", .{ledger});

    // A deposit: the bank's debit is the customer's credit.
    const deposit = try r.transfers.create(transfer(takeId(&next_id), bank, customer, 1000, code_deposit)).commit();
    try out.print("deposit: {d}\n", .{deposit.amount});

    // A purchase and its fee, all or nothing.
    _ = try r.transfers.linked()
        .add(transfer(takeId(&next_id), customer, bank, 250, code_purchase))
        .add(transfer(takeId(&next_id), customer, bank, 5, code_fee))
        .commit();
    try out.print("linked: purchase 250 + fee 5, both posted\n", .{});

    // The customer has 745: the withdrawal fits, the fee after it doesn't,
    // so neither is posted.
    var failure: Transfers.Linked().Failure = undefined;
    const refused = r.transfers.linked()
        .add(transfer(takeId(&next_id), customer, bank, 740, code_withdrawal))
        .add(transfer(takeId(&next_id), customer, bank, 10, code_fee))
        .reportTo(&failure)
        .commit();
    if (refused) |_| return error.ExpectedRefusal else |err| switch (err) {
        error.ExceedsCredits => try out.print("refused: withdrawal 740 + fee 10: event {d} failed with {t}, nothing posted\n", .{ failure.index, err }),
        else => return err,
    }

    // The balances: one lookup_accounts for both.
    const both = [_]u128{ bank, customer };
    const accounts = try r.accounts.whereIn(.id, &both).toSlice(arena);
    try out.print("balances:\n", .{});
    for (accounts) |account| {
        const net: i129 = @as(i129, account.credits_posted) - account.debits_posted;
        try out.print("  {s:<8}  debits {d:>4}  credits {d:>4}  net {d:>5}\n", .{
            if (account.id == bank) "bank" else "customer",
            account.debits_posted,
            account.credits_posted,
            net,
        });
    }

    // The customer's history: its transfers (get_account_transfers), and
    // its balance after each (get_account_balances), oldest first.
    const transfers = try r.accounts.byPk(customer)
        .combine(.transfers, r.transfers.order(.timestamp, .asc))
        .mapTo(struct { id: u128, transfers: []const tb.Transfer }, arena);
    const balances = try r.accounts.byPk(customer)
        .combine(.balances, r.balances.order(.timestamp, .asc))
        .mapTo(struct { id: u128, balances: []const tb.AccountBalance }, arena);
    try out.print("customer history:\n", .{});
    for (transfers.items[0].transfers, balances.items[0].balances) |t, after| {
        std.debug.assert(t.timestamp == after.timestamp);
        const sign: u8 = if (t.credit_account_id == customer) '+' else '-';
        try out.print("  {c}{d:<5} balance {d}\n", .{ sign, t.amount, after.credits_posted - after.debits_posted });
    }
    try out.flush();
}

/// The next id of this run.
fn takeId(next: *u128) u128 {
    next.* += 1;
    return next.*;
}

fn transfer(id: u128, debit: u128, credit: u128, amount: u128, code: u16) tb.Transfer {
    return .{ .id = id, .debit_account_id = debit, .credit_account_id = credit, .amount = amount, .ledger = ledger, .code = code };
}

/// The first argument, or else TB_ADDRESSES.
fn addresses(init: std.process.Init) ![]const u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) return args[1];
    return init.environ_map.get("TB_ADDRESSES") orelse {
        std.log.err("no cluster: set TB_ADDRESSES (e.g. 3000), or pass it as the first argument", .{});
        return error.NoAddresses;
    };
}
