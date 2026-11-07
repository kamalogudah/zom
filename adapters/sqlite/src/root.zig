//! zom-sqlite: a zom gateway for SQLite, on the SQLite amalgamation
//! compiled into the module (no system library, no third-party wrapper).
//!
//!     var gateway = try zom_sqlite.Gateway.init(allocator, .{ .path = "app.db" });
//!     defer gateway.deinit();
//!     const users = try zom.Relation(UserSchema, zom_sqlite.Gateway).init(&gateway);
//!
//!     const adults = try users.where(.age, .gte, 18).toSlice(allocator);
//!     defer users.free(allocator, adults); // strings are the caller's
//!
//! Statements come from zom-sql; see gateway.zig for binding, decoding,
//! errors and string ownership, and README.md for setup.

pub const Gateway = @import("gateway.zig").Gateway;
pub const SqliteError = @import("gateway.zig").SqliteError;
/// The translated `sqlite3.h`, for `Gateway.handle()`.
pub const c = @import("sqlite3");

test {
    _ = @import("gateway.zig");
    _ = @import("lint_test.zig");
    _ = @import("scenario_test.zig");
    _ = @import("join_test.zig");
    _ = @import("combine_test.zig");
    _ = @import("transaction_test.zig");
}
