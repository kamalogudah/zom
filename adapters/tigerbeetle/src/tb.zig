//! TigerBeetle's types, as `tb_client.h` declares them.
//!
//! `Account` and `Transfer` are the C client's own structs (translated by
//! the translate-c package, with `default_init`), not mirrors: they are `extern struct`s of plain
//! integers (`u128` ids, amounts and `user_data_128`, `u64`, `u32`, `u16`),
//! every field defaulting to 0, 128 bytes each. `flags` is a `u16` there,
//! so zom stores, compares and filters it like any other integer. The
//! typed views `AccountFlags` and `TransferFlags` are `packed struct(u16)`s
//! of bools, converted with `@bitCast`:
//!
//!     var account: tb.Account = .{ .id = 1, .ledger = 700, .code = 10 };
//!     account.flags = tb.AccountFlags.bits(.{ .history = true });
//!     const flags = tb.AccountFlags.of(account); // flags.history == true

const std = @import("std");

/// The whole translated header: every `tb_*` type, `TB_*` constant and
/// `tb_client_*` function.
pub const c = @import("tb_client");

pub const Account = c.tb_account_t;
pub const Transfer = c.tb_transfer_t;

/// One row of an account's balance history, as `get_account_balances`
/// returns it (`tb_account_balance_t`: the account's four balances just
/// after the transfer with this `timestamp`), plus the account it is of,
/// which the C struct leaves out because the request names it. The tuple of
/// the `zom_tigerbeetle.AccountBalance` view; only accounts created with
/// `flags.history` have rows.
pub const AccountBalance = struct {
    account_id: u128 = 0,
    timestamp: u64 = 0,
    debits_pending: u128 = 0,
    debits_posted: u128 = 0,
    credits_pending: u128 = 0,
    credits_posted: u128 = 0,

    /// `balance` (a reply record) of `account_id`.
    pub fn of(account_id: u128, balance: c.tb_account_balance_t) AccountBalance {
        return .{
            .account_id = account_id,
            .timestamp = balance.timestamp,
            .debits_pending = balance.debits_pending,
            .debits_posted = balance.debits_posted,
            .credits_pending = balance.credits_pending,
            .credits_posted = balance.credits_posted,
        };
    }
};

/// The most events one `create_accounts` / `create_transfers` request takes
/// in TigerBeetle's default configuration (docs/coding/requests.md). The
/// cluster sets the real limit (a `--development` one takes 253), and the
/// client learns it but `tb_client.h` doesn't expose it, so this is only
/// where `insertMany` starts: see `Gateway.Config.batch_max`. A bigger
/// request gets `TB_PACKET_TOO_MUCH_DATA` from the client, unsent.
pub const batch_max: u32 = 8189;

/// Bit 0 of `flags`, for both records: this event and the next one succeed
/// or fail together.
pub const linked_flag: u16 = c.TB_ACCOUNT_LINKED;

/// `Account.flags` as bools, bit 0 first, as in `TB_ACCOUNT_FLAGS`.
pub const AccountFlags = packed struct(u16) {
    linked: bool = false,
    debits_must_not_exceed_credits: bool = false,
    credits_must_not_exceed_debits: bool = false,
    history: bool = false,
    imported: bool = false,
    closed: bool = false,
    padding: u10 = 0,

    pub const bits = FlagsMethods(AccountFlags, Account).bits;
    pub const of = FlagsMethods(AccountFlags, Account).of;
};

/// `Transfer.flags` as bools, bit 0 first, as in `TB_TRANSFER_FLAGS`.
pub const TransferFlags = packed struct(u16) {
    linked: bool = false,
    pending: bool = false,
    post_pending_transfer: bool = false,
    void_pending_transfer: bool = false,
    balancing_debit: bool = false,
    balancing_credit: bool = false,
    closing_debit: bool = false,
    closing_credit: bool = false,
    imported: bool = false,
    padding: u7 = 0,

    pub const bits = FlagsMethods(TransferFlags, Transfer).bits;
    pub const of = FlagsMethods(TransferFlags, Transfer).of;
};

fn FlagsMethods(comptime Flags: type, comptime Record: type) type {
    return struct {
        /// The `flags` value for `flags`.
        pub fn bits(flags: Flags) u16 {
            return @bitCast(flags);
        }

        /// `record.flags` as bools. The padding bits are kept as they are.
        pub fn of(record: Record) Flags {
            return @bitCast(record.flags);
        }
    };
}

// The layout the wire format and the C ABI fix. A newer tb_client.h that
// changes it must fail here, not at runtime.
comptime {
    for (.{ Account, Transfer }) |T| {
        std.debug.assert(@sizeOf(T) == 128);
        std.debug.assert(@alignOf(T) == 16);
        std.debug.assert(@typeInfo(T).@"struct".layout == .@"extern");
    }
    // A balance reply record is as big as the others, so a page holds as many.
    std.debug.assert(@sizeOf(c.tb_account_balance_t) == 128);
    std.debug.assert(@FieldType(Account, "flags") == u16);
    std.debug.assert(@FieldType(Transfer, "flags") == u16);
    std.debug.assert(c.TB_ACCOUNT_LINKED == c.TB_TRANSFER_LINKED);
}

const testing = std.testing;

test "the flag bits match TB_ACCOUNT_FLAGS and TB_TRANSFER_FLAGS" {
    const account = .{
        .{ "linked", c.TB_ACCOUNT_LINKED },
        .{ "debits_must_not_exceed_credits", c.TB_ACCOUNT_DEBITS_MUST_NOT_EXCEED_CREDITS },
        .{ "credits_must_not_exceed_debits", c.TB_ACCOUNT_CREDITS_MUST_NOT_EXCEED_DEBITS },
        .{ "history", c.TB_ACCOUNT_HISTORY },
        .{ "imported", c.TB_ACCOUNT_IMPORTED },
        .{ "closed", c.TB_ACCOUNT_CLOSED },
    };
    inline for (account) |pair| {
        var flags: AccountFlags = .{};
        @field(flags, pair[0]) = true;
        try testing.expectEqual(@as(u16, pair[1]), AccountFlags.bits(flags));
    }
    const transfer = .{
        .{ "linked", c.TB_TRANSFER_LINKED },
        .{ "pending", c.TB_TRANSFER_PENDING },
        .{ "post_pending_transfer", c.TB_TRANSFER_POST_PENDING_TRANSFER },
        .{ "void_pending_transfer", c.TB_TRANSFER_VOID_PENDING_TRANSFER },
        .{ "balancing_debit", c.TB_TRANSFER_BALANCING_DEBIT },
        .{ "balancing_credit", c.TB_TRANSFER_BALANCING_CREDIT },
        .{ "closing_debit", c.TB_TRANSFER_CLOSING_DEBIT },
        .{ "closing_credit", c.TB_TRANSFER_CLOSING_CREDIT },
        .{ "imported", c.TB_TRANSFER_IMPORTED },
    };
    inline for (transfer) |pair| {
        var flags: TransferFlags = .{};
        @field(flags, pair[0]) = true;
        try testing.expectEqual(@as(u16, pair[1]), TransferFlags.bits(flags));
    }
}

test "flags round-trip through a record" {
    var t: Transfer = .{ .id = 1, .ledger = 700, .code = 1 };
    t.flags = TransferFlags.bits(.{ .linked = true, .pending = true });
    try testing.expectEqual(@as(u16, 0b11), t.flags);
    const back = TransferFlags.of(t);
    try testing.expect(back.linked and back.pending and !back.imported);
}
