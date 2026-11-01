//! zom.lint against a live Postgres. Skipped unless `ZOM_PG_URL` is set:
//!
//!     ZOM_PG_URL=postgres://postgres:postgres@127.0.0.1:5432/zom_test zig build test
//!
//! Every check drops and recreates the `lint_users` table, so point it at a
//! database you don't mind losing that table in.

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const G = zom_pg.Gateway;

/// The columns are not in `zom.lint.User`'s field order, so decoding by
/// position instead of name (`RETURNING *` gives table order) would fail.
/// `id` is a `u32`, which needs `bigint`; `age` is a `?u8`, held in a
/// `smallint` that would also take values a `u8` can't.
const create_table =
    \\CREATE TABLE lint_users (
    \\  role text NOT NULL,
    \\  id bigint PRIMARY KEY,
    \\  age smallint,
    \\  name text NOT NULL
    \\)
;

fn url(allocator: Allocator) ![]u8 {
    return testing.environ.getAlloc(allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => error.SkipZigTest,
        else => |e| e,
    };
}

const Factory = struct {
    pub fn create(allocator: Allocator) !G {
        const u = try url(allocator);
        defer allocator.free(u);
        var g = try G.init(allocator, .{ .io = testing.io, .url = u, .pool_size = 2 });
        errdefer g.deinit();
        try g.exec("DROP TABLE IF EXISTS lint_users");
        try g.exec(create_table);
        return g;
    }
    pub fn destroy(g: *G) void {
        g.exec("DROP TABLE IF EXISTS lint_users") catch {};
        g.deinit();
    }
};

test "zom-pg passes zom.lint" {
    // Skip before lint prints a failure for every check.
    testing.allocator.free(try url(testing.allocator));
    try zom.lint.run(G, Factory);
}

test "the gateway satisfies the adapter contract" {
    const A = zom.Adapter(G);
    try testing.expectEqualStrings("postgres", A.name);
    try testing.expectEqual(zom.StringOwnership.caller, A.stringOwnership(zom.lint.Users));
    try testing.expect(A.has(zom.lint.Users, .writable));
    try testing.expect(A.has(zom.lint.Users, .batch_insert));
    try testing.expect(A.has(zom.lint.Users, .updatable));
    try testing.expect(A.has(zom.lint.Users, .deletable));
}
