//! The two fixed schemas. TigerBeetle has exactly these datasets, with
//! these fields, keyed by `id`.

const zom = @import("zom");
const tb = @import("tb.zig");

pub const Account = zom.Schema(tb.Account, "accounts", .id, .{});
pub const Transfer = zom.Schema(tb.Transfer, "transfers", .id, .{});
