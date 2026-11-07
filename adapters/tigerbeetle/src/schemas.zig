//! The fixed schemas. TigerBeetle has exactly two datasets, accounts and
//! transfers, with these fields, keyed by `id`; `AccountBalance` is a
//! read-only view of an account's balance history.
//!
//! The associations (the `struct { pub const ... }` form, because they
//! point at each other; see zom's schema.zig):
//!
//! - `Account.transfers`: every transfer the account is the debit *or* the
//!   credit account of, which no single foreign key says, so it is a
//!   `zom.customAssociation` that the transfers dataset loads through
//!   `get_account_transfers` (see `loadAssociation` in gateway.zig).
//! - `Account.balances`: a plain `hasMany` of `AccountBalance` rows by
//!   `account_id`, read through `get_account_balances`.
//! - `Transfer.debit_account` / `.credit_account`: `belongsTo`s, read
//!   through `lookup_accounts`.
//! - `AccountBalance.account`: the `belongsTo` back.

const zom = @import("zom");
const tb = @import("tb.zig");

pub const Account = zom.Schema(tb.Account, "accounts", .id, .{
    .associations = struct {
        pub const transfers = zom.customAssociation(Transfer, .account_transfers, .many);
        pub const balances = zom.hasMany(AccountBalance, .account_id);
    },
});

pub const Transfer = zom.Schema(tb.Transfer, "transfers", .id, .{
    .associations = struct {
        pub const debit_account = zom.belongsTo(Account, .debit_account_id);
        pub const credit_account = zom.belongsTo(Account, .credit_account_id);
    },
});

/// Read only, and only for given accounts: a read needs an `account_id`
/// filter (`eq` or `in`), since `get_account_balances` takes one account.
/// A view without a primary key: a row is unique per `account_id` and
/// `timestamp` (the transfer it follows), but `timestamp` alone is not
/// unique, since a transfer moves the balances of both its accounts. So
/// `byPk` is a compile error; one row is
/// `where(.account_id, .eq, a).where(.timestamp, .eq, ts)`.
pub const AccountBalance = zom.Schema(tb.AccountBalance, "account_balances", null, .{
    .associations = struct {
        pub const account = zom.belongsTo(Account, .account_id);
    },
});
