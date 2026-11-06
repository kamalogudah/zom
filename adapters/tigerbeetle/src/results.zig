//! The result codes of `create_accounts` and `create_transfers`, and the
//! errors they become.
//!
//! `CreateAccountResult` and `CreateTransferResult` are generated at compile
//! time from the `TB_CREATE_ACCOUNT_*` / `TB_CREATE_TRANSFER_*` constants of
//! `tb_client.h`, so they always match the linked client: `TB_CREATE_TRANSFER_EXCEEDS_CREDITS`
//! is `.exceeds_credits`, with the same value.
//!
//! Zig can't build an error set at compile time (0.16 has `@Enum`, `@Struct`
//! and `@Union`, but nothing for error sets), so `CreateAccountError` and
//! `CreateTransferError` are written out below: `.exceeds_credits` is
//! `error.ExceedsCredits`. `errorOf` maps a code to its error by name, and it
//! fails to compile when a code has no error, so a client upgrade that adds
//! a code can't be missed. A test checks the other direction (no error left
//! over from a code that was removed).
//!
//! Three codes are no error of their own:
//! - `.created` is success.
//! - `.exists` and every `.exists_with_different_*` mean the id is taken,
//!   which is zom's `error.DuplicatePrimaryKey` (`zom.Error`). The exact code
//!   is in `insertManyResults`.

const std = @import("std");
const c = @import("tb.zig").c;

/// The result of one `create_accounts` event: `.created`, or why not.
/// Non-exhaustive, because a newer cluster may answer with a code this
/// client doesn't know.
pub const CreateAccountResult = CodeEnum("TB_CREATE_ACCOUNT_");

/// The result of one `create_transfers` event: `.created`, or why not.
pub const CreateTransferResult = CodeEnum("TB_CREATE_TRANSFER_");

/// One error per `CreateAccountResult` code, except `.created` and the
/// `.exists*` codes (see the file comment).
pub const CreateAccountError = error{
    LinkedEventFailed,
    LinkedEventChainOpen,
    ImportedEventExpected,
    ImportedEventNotExpected,
    TimestampMustBeZero,
    ImportedEventTimestampOutOfRange,
    ImportedEventTimestampMustNotAdvance,
    ReservedField,
    ReservedFlag,
    IdMustNotBeZero,
    IdMustNotBeIntMax,
    FlagsAreMutuallyExclusive,
    DebitsPendingMustBeZero,
    DebitsPostedMustBeZero,
    CreditsPendingMustBeZero,
    CreditsPostedMustBeZero,
    LedgerMustNotBeZero,
    CodeMustNotBeZero,
    ImportedEventTimestampMustNotRegress,
};

/// One error per `CreateTransferResult` code, except `.created` and the
/// `.exists*` codes (see the file comment).
pub const CreateTransferError = error{
    LinkedEventFailed,
    LinkedEventChainOpen,
    ImportedEventExpected,
    ImportedEventNotExpected,
    TimestampMustBeZero,
    ImportedEventTimestampOutOfRange,
    ImportedEventTimestampMustNotAdvance,
    ReservedFlag,
    IdMustNotBeZero,
    IdMustNotBeIntMax,
    IdAlreadyFailed,
    FlagsAreMutuallyExclusive,
    DebitAccountIdMustNotBeZero,
    DebitAccountIdMustNotBeIntMax,
    CreditAccountIdMustNotBeZero,
    CreditAccountIdMustNotBeIntMax,
    AccountsMustBeDifferent,
    PendingIdMustBeZero,
    PendingIdMustNotBeZero,
    PendingIdMustNotBeIntMax,
    PendingIdMustBeDifferent,
    TimeoutReservedForPendingTransfer,
    ClosingTransferMustBePending,
    LedgerMustNotBeZero,
    CodeMustNotBeZero,
    DebitAccountNotFound,
    CreditAccountNotFound,
    AccountsMustHaveTheSameLedger,
    TransferMustHaveTheSameLedgerAsAccounts,
    PendingTransferNotFound,
    PendingTransferNotPending,
    PendingTransferHasDifferentDebitAccountId,
    PendingTransferHasDifferentCreditAccountId,
    PendingTransferHasDifferentLedger,
    PendingTransferHasDifferentCode,
    ExceedsPendingTransferAmount,
    PendingTransferHasDifferentAmount,
    PendingTransferAlreadyPosted,
    PendingTransferAlreadyVoided,
    PendingTransferExpired,
    ImportedEventTimestampMustNotRegress,
    ImportedEventTimestampMustPostdateDebitAccount,
    ImportedEventTimestampMustPostdateCreditAccount,
    ImportedEventTimeoutMustBeZero,
    DebitAccountAlreadyClosed,
    CreditAccountAlreadyClosed,
    OverflowsDebitsPending,
    OverflowsCreditsPending,
    OverflowsDebitsPosted,
    OverflowsCreditsPosted,
    OverflowsDebits,
    OverflowsCredits,
    OverflowsTimeout,
    ExceedsCredits,
    ExceedsDebits,
};

/// What `errorOf` returns besides `E`: the id is taken, or the cluster sent
/// a code this client doesn't know (it is logged by the caller).
pub const OtherError = error{ DuplicatePrimaryKey, UnknownResult };

/// The error for `code`, or null for `.created`. `Code` is
/// `CreateAccountResult` or `CreateTransferResult` and `E` its error set.
pub fn errorOf(comptime Code: type, comptime E: type, code: Code) ?(E || OtherError) {
    @setEvalBranchQuota(100_000);
    if (code == .created) return null;
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        if (comptime std.mem.eql(u8, f.name, "created")) continue;
        if (@intFromEnum(code) == f.value) {
            if (comptime isExists(f.name)) return error.DuplicatePrimaryKey;
            const err_name = comptime pascal(f.name);
            if (comptime !hasError(E, err_name))
                @compileError("zom-tigerbeetle: result code `." ++ f.name ++ "` of " ++ setName(Code) ++
                    "Result has no error: add `" ++ err_name ++ "` to " ++ setName(Code) ++ "Error in results.zig");
            return @field(E, err_name);
        }
    }
    return error.UnknownResult;
}

/// "CreateAccount" or "CreateTransfer", for messages.
fn setName(comptime Code: type) []const u8 {
    return if (Code == CreateAccountResult) "CreateAccount" else "CreateTransfer";
}

fn isExists(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "exists") or std.mem.startsWith(u8, name, "exists_with_different_");
}

fn hasError(comptime E: type, comptime name: []const u8) bool {
    for (@typeInfo(E).error_set.?) |e| if (std.mem.eql(u8, e.name, name)) return true;
    return false;
}

/// An enum of every integer constant of `tb_client.h` named `prefix ++ X`,
/// as the field `x` (lower case). The header's enum type itself (e.g.
/// `TB_CREATE_ACCOUNT_STATUS`) is a type, not an integer, so it's skipped.
fn CodeEnum(comptime prefix: []const u8) type {
    comptime {
        // Hundreds of header decls, each name walked a character at a time.
        @setEvalBranchQuota(100_000);
        var names: []const []const u8 = &.{};
        var values: []const u32 = &.{};
        for (@typeInfo(c).@"struct".decls) |decl| {
            if (!std.mem.startsWith(u8, decl.name, prefix)) continue;
            const value = @field(c, decl.name);
            if (@typeInfo(@TypeOf(value)) != .int) continue;
            names = names ++ .{lower(decl.name[prefix.len..])};
            values = values ++ .{@as(u32, value)};
        }
        if (names.len == 0) @compileError("zom-tigerbeetle: tb_client.h has no " ++ prefix ++ "* constants");
        return @Enum(u32, .nonexhaustive, names, values[0..names.len]);
    }
}

fn lower(comptime s: []const u8) []const u8 {
    comptime {
        var buf: [s.len]u8 = undefined;
        for (&buf, s) |*out, ch| out.* = std.ascii.toLower(ch);
        const final = buf;
        return &final;
    }
}

/// `exceeds_credits` -> `ExceedsCredits`.
fn pascal(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var it = std.mem.splitScalar(u8, s, '_');
        while (it.next()) |word| {
            if (word.len == 0) continue;
            out = out ++ .{std.ascii.toUpper(word[0])} ++ word[1..];
        }
        return out;
    }
}

const testing = std.testing;

test "the codes are the header's" {
    try testing.expectEqual(c.TB_CREATE_ACCOUNT_CREATED, @intFromEnum(CreateAccountResult.created));
    try testing.expectEqual(c.TB_CREATE_ACCOUNT_EXISTS, @intFromEnum(CreateAccountResult.exists));
    try testing.expectEqual(c.TB_CREATE_TRANSFER_EXCEEDS_CREDITS, @intFromEnum(CreateTransferResult.exceeds_credits));
    try testing.expectEqual(c.TB_CREATE_TRANSFER_LINKED_EVENT_FAILED, @intFromEnum(CreateTransferResult.linked_event_failed));
}

fn expectMapping(comptime Code: type, comptime E: type) !void {
    @setEvalBranchQuota(100_000);
    // Every code maps (errorOf would not compile otherwise)...
    var mapped: usize = 0;
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const code: Code = @enumFromInt(f.value);
        const err = errorOf(Code, E, code);
        if (std.mem.eql(u8, f.name, "created")) {
            try testing.expectEqual(null, err);
        } else if (comptime isExists(f.name)) {
            try testing.expectEqual(error.DuplicatePrimaryKey, err.?);
        } else {
            try testing.expectEqualStrings(comptime pascal(f.name), @errorName(err.?));
            mapped += 1;
        }
    }
    // ...and every error is some code's, so none is left over.
    try testing.expectEqual(@typeInfo(E).error_set.?.len, mapped);
}

test "every result code has an error, and every error a code" {
    try expectMapping(CreateAccountResult, CreateAccountError);
    try expectMapping(CreateTransferResult, CreateTransferError);
}

test "a code the client doesn't know is UnknownResult" {
    const code: CreateTransferResult = @enumFromInt(9999);
    try testing.expectEqual(error.UnknownResult, errorOf(CreateTransferResult, CreateTransferError, code).?);
}
