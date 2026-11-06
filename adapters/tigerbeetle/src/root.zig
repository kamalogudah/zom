//! zom-tigerbeetle: a zom gateway for TigerBeetle, on its C client.
//!
//!     var gateway = try zom_tigerbeetle.Gateway.init(allocator, .{
//!         .io = io,
//!         .cluster_id = 0,
//!         .addresses = "3000",
//!     });
//!     defer gateway.deinit();
//!     const accounts = try zom.Relation(zom_tigerbeetle.Account, zom_tigerbeetle.Gateway).init(&gateway);
//!
//! The schemas are fixed: `Account` and `Transfer`, over the client's own
//! `tb.Account` and `tb.Transfer` structs, keyed by `id`. Records are
//! immutable, so there is no update or delete: `create` and `createMany`
//! are the writes, and fail with the result code's error
//! (`error.ExceedsCredits`, ...; see results.zig). See gateway.zig, and
//! README.md for how the client library is fetched and linked.

/// TigerBeetle's types: `tb.Account`, `tb.Transfer`, the typed flags, and
/// the whole translated `tb_client.h` as `tb.c`.
pub const tb = @import("tb.zig");

pub const Account = @import("schemas.zig").Account;
pub const Transfer = @import("schemas.zig").Transfer;

pub const Gateway = @import("gateway.zig").Gateway;

/// The result codes of `create_accounts` / `create_transfers` and the
/// typed errors they become (`error.ExceedsCredits`, ...).
pub const results = @import("results.zig");

test {
    _ = tb;
    _ = results;
    _ = @import("gateway.zig");
    _ = @import("gateway_test.zig");
}
