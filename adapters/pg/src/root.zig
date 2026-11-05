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
pub const ServerError = @import("gateway.zig").ServerError;
pub const Diagnostics = @import("verify.zig").Diagnostics;
pub const Mismatch = @import("verify.zig").Mismatch;
pub const pgTypesFor = @import("verify.zig").pgTypesFor;
pub const zigTypeFor = @import("verify.zig").zigTypeFor;
pub const Introspection = @import("introspect.zig").Introspection;

test {
    _ = @import("gateway.zig");
    _ = @import("lint_test.zig");
    _ = @import("scenario_test.zig");
    _ = @import("join_test.zig");
    _ = @import("transaction_test.zig");
    _ = @import("verify.zig");
    _ = @import("verify_test.zig");
    _ = @import("introspect_test.zig");
}
