//! zom-pg: a zom gateway for PostgreSQL, on karlseguin/pg.zig.
//!
//!     var gateway = try zom_pg.Gateway.init(allocator, .{ .io = io, .url = "postgres://localhost/app" });
//!     defer gateway.deinit();
//!     const users = try zom.Relation(UserSchema, zom_pg.Gateway).init(&gateway);
//!
//!     const adults = try users.where(.age, .gte, 18).toSlice(allocator);
//!     defer users.free(allocator, adults); // strings are the caller's
//!
//! Statements come from zom-sql; see gateway.zig for binding, decoding,
//! errors and string ownership, and README.md for setup.

pub const Gateway = @import("gateway.zig").Gateway;

test {
    _ = @import("gateway.zig");
    _ = @import("lint_test.zig");
}
