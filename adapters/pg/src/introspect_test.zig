//! `Gateway.introspect` and `zom_sql.infer.render` against a live Postgres.
//! Skipped unless `ZOM_PG_URL` is set (see lint_test.zig). Each test drops
//! and recreates the `zom_infer` schema.
//!
//! `testdata/infer_pg.zig` is the expected output. It is also imported
//! here, so it must compile, and `verify` must accept its schemas against
//! the tables they came from.

const std = @import("std");
const zom = @import("zom");
const zom_sql = @import("zom_sql");
const zom_pg = @import("root.zig");
const testing = std.testing;

const G = zom_pg.Gateway;
const generated = @import("testdata/infer_pg.zig");

const setup = [_][]const u8{
    "DROP SCHEMA IF EXISTS zom_infer CASCADE",
    "CREATE SCHEMA zom_infer",
    "CREATE TYPE zom_infer.user_role AS ENUM ('admin', 'member', 'in progress')",
    \\CREATE TABLE zom_infer.users (
    \\  id integer PRIMARY KEY,
    \\  name text NOT NULL,
    \\  email varchar(255),
    \\  role zom_infer.user_role NOT NULL DEFAULT 'member',
    \\  karma bigint NOT NULL,
    \\  rank smallint,
    \\  score double precision,
    \\  ratio real,
    \\  price numeric(10, 2),
    \\  active boolean NOT NULL,
    \\  code char(3),
    \\  created_at timestamptz NOT NULL DEFAULT now()
    \\)
    ,
    \\CREATE TABLE zom_infer."2fa codes" ("user id" integer PRIMARY KEY, "type" text NOT NULL)
    ,
    "CREATE TABLE zom_infer.events (body text)",
    "CREATE TABLE zom_infer.memberships (user_id integer, group_id integer, PRIMARY KEY (user_id, group_id))",
    "CREATE TABLE zom_infer.sessions (token uuid PRIMARY KEY)",
    // Views are left out.
    "CREATE VIEW zom_infer.active_users AS SELECT id FROM zom_infer.users WHERE active",
};

fn open() !G {
    const u = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(u);
    // One connection, so the `search_path` set below holds for every call.
    var g = try G.init(testing.allocator, .{ .io = testing.io, .url = u, .pool_size = 1 });
    errdefer g.deinit();
    for (setup) |sql| try g.exec(sql);
    return g;
}

test "introspect + render matches testdata/infer_pg.zig" {
    var g = try open();
    defer g.deinit();
    var found = try g.introspect(testing.allocator, "zom_infer");
    defer found.deinit();

    const source = try zom_sql.infer.render(testing.allocator, found.catalog, .{});
    defer testing.allocator.free(source);
    try testing.expectEqualStrings(@embedFile("testdata/infer_pg.zig"), source);
}

test "verify accepts the generated schemas, and they read and write" {
    var g = try open();
    defer g.deinit();
    try g.exec("SET search_path TO zom_infer");

    var diag: G.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    g.verify(generated.UsersSchema, &diag) catch |err| {
        std.debug.print("{f}\n", .{diag});
        return err;
    };
    try g.verify(generated.@"2faCodesSchema", null);

    const users = try zom.Relation(generated.UsersSchema, G).init(&g);
    const stored = try users.create(.{
        .id = 1,
        .name = "Achieng",
        .role = .@"in progress",
        .karma = 10,
        .active = true,
    }).commitAlloc(testing.allocator);
    defer users.freeOne(testing.allocator, stored);

    const back = (try users.byPk(1).one(testing.allocator)).?;
    defer users.freeOne(testing.allocator, back);
    try testing.expectEqualStrings("Achieng", back.name);
    try testing.expectEqual(.@"in progress", back.role);
    try testing.expectEqual(null, back.email);
}

test "introspect: an unknown schema is error.SchemaNotFound" {
    var g = try open();
    defer g.deinit();
    try testing.expectError(error.SchemaNotFound, g.introspect(testing.allocator, "zom_infer_missing"));
}
