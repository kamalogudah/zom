//! zom.lint against SQLite. Each check gets a fresh in-memory database, so
//! it always runs: no server, no environment variable.

const std = @import("std");
const zom = @import("zom");
const zom_sqlite = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const G = zom_sqlite.Gateway;

/// The columns are not in `zom.lint.User`'s field order, so decoding by
/// position instead of name (`RETURNING *` gives table order) would fail.
/// `STRICT` makes SQLite check each value's type, as Postgres would.
pub const ddl =
    \\CREATE TABLE lint_users (
    \\  role TEXT NOT NULL,
    \\  id INTEGER PRIMARY KEY,
    \\  age INTEGER,
    \\  name TEXT NOT NULL
    \\) STRICT;
    \\CREATE TABLE lint_posts (
    \\  id INTEGER PRIMARY KEY,
    \\  user_id INTEGER,
    \\  title TEXT NOT NULL,
    \\  published INTEGER NOT NULL
    \\) STRICT;
    \\CREATE TABLE lint_comments (
    \\  id INTEGER PRIMARY KEY,
    \\  user_id INTEGER,
    \\  body TEXT NOT NULL,
    \\  flagged INTEGER NOT NULL
    \\) STRICT;
;

const Factory = struct {
    pub fn create(allocator: Allocator) !G {
        var g = try G.init(allocator, .{});
        errdefer g.deinit();
        try g.exec(ddl);
        return g;
    }
    pub fn destroy(g: *G) void {
        g.deinit();
    }
};

test "zom-sqlite passes zom.lint" {
    try zom.lint.run(G, Factory);
}

test "zom-sqlite passes zom.lint with the statement cache off" {
    const NoCache = struct {
        pub fn create(allocator: Allocator) !G {
            var g = try G.init(allocator, .{ .statement_cache_size = 0 });
            errdefer g.deinit();
            try g.exec(ddl);
            return g;
        }
        pub const destroy = Factory.destroy;
    };
    try zom.lint.run(G, NoCache);
}

test "the gateway satisfies the adapter contract" {
    const A = zom.Adapter(G);
    try testing.expectEqualStrings("sqlite", A.name);
    try testing.expectEqual(zom.StringOwnership.caller, A.stringOwnership(zom.lint.Users));
    try testing.expect(A.has(zom.lint.Users, .writable));
    try testing.expect(A.has(zom.lint.Users, .batch_insert));
    try testing.expect(A.has(zom.lint.Users, .updatable));
    try testing.expect(A.has(zom.lint.Users, .deletable));
    try testing.expect(A.has(zom.lint.Users, .transaction));
}
