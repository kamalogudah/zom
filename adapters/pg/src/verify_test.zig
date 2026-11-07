//! `Gateway.verify` against a live Postgres. Skipped unless `ZOM_PG_URL` is
//! set (see lint_test.zig). Each test drops and recreates the `vf_users`
//! table (and the `vf_role` type).

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("root.zig");
const testing = std.testing;

const G = zom_pg.Gateway;

const Role = enum { admin, member };
const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    score: f64,
    active: bool,
    role: Role,
};
const Users = zom.Schema(User, "vf_users", .id, .{});

/// Matches `User`, with the columns in another order and one the struct
/// doesn't have.
const good_table =
    \\CREATE TABLE vf_users (
    \\  role text NOT NULL,
    \\  id bigint PRIMARY KEY,
    \\  name varchar(64) NOT NULL,
    \\  created_at timestamptz NOT NULL DEFAULT now(),
    \\  age smallint,
    \\  score double precision NOT NULL,
    \\  active boolean NOT NULL
    \\)
;

fn open(create_sql: []const u8) !G {
    const u = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(u);
    var g = try G.init(testing.allocator, .{ .io = testing.io, .url = u, .pool_size = 1 });
    errdefer g.deinit();
    try g.exec("DROP TABLE IF EXISTS vf_users");
    try g.exec("DROP TYPE IF EXISTS vf_role");
    if (create_sql.len != 0) try g.exec(create_sql);
    return g;
}

fn close(g: *G) void {
    g.exec("DROP TABLE IF EXISTS vf_users") catch {};
    g.exec("DROP TYPE IF EXISTS vf_role") catch {};
    g.deinit();
}

/// Runs `verify(Users)` on a table made by `sqls`, and checks the
/// diagnostics read `expected`, one mismatch per line ("" for none).
fn expectDiagnostics(sqls: []const []const u8, expected: []const u8) !void {
    var g = try open("");
    defer close(&g);
    for (sqls) |s| try g.exec(s);

    var diag: zom_pg.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    const result = g.verify(Users, &diag);

    const text = try testing.allocator.print("{f}", .{diag});
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(expected, text);
    if (expected.len == 0) try result else try testing.expectError(error.SchemaMismatch, result);
}

test "verify: a matching table passes" {
    try expectDiagnostics(&.{good_table}, "");
}

test "verify: a Postgres ENUM holds a Zig enum" {
    try expectDiagnostics(&.{
        "CREATE TYPE vf_role AS ENUM ('admin', 'member')",
        "CREATE TABLE vf_users (id bigint PRIMARY KEY, name text NOT NULL, age integer, score numeric NOT NULL, active boolean NOT NULL, role vf_role NOT NULL)",
    }, "");
}

test "verify: a missing column" {
    try expectDiagnostics(&.{
        "CREATE TABLE vf_users (id bigint PRIMARY KEY, name text NOT NULL, score double precision NOT NULL, active boolean NOT NULL, role text NOT NULL)",
    }, "vf_users.age: Zig ?u8 vs no column");
}

test "verify: wrong types, all reported at once" {
    try expectDiagnostics(&.{
        // id: a u32 doesn't fit an integer. age: text. score: an f64 in a
        // real loses precision. active: an int isn't a boolean.
        "CREATE TABLE vf_users (id integer PRIMARY KEY, name text NOT NULL, age text, score real NOT NULL, active smallint NOT NULL, role text NOT NULL)",
    },
        \\vf_users.id: Zig u32 vs pg integer
        \\vf_users.age: Zig ?u8 vs pg text
        \\vf_users.score: Zig f64 vs pg real
        \\vf_users.active: Zig bool vs pg smallint
    );
}

test "verify: an enum needs text or a Postgres ENUM" {
    try expectDiagnostics(&.{
        "CREATE TABLE vf_users (id bigint PRIMARY KEY, name text NOT NULL, age smallint, score float8 NOT NULL, active boolean NOT NULL, role integer NOT NULL)",
    }, "vf_users.role: Zig verify_test.Role vs pg integer");
}

test "verify: nullability mismatches, both ways" {
    try expectDiagnostics(&.{
        // name is nullable but the field isn't; age is NOT NULL but the field is optional.
        "CREATE TABLE vf_users (id bigint PRIMARY KEY, name text, age smallint NOT NULL, score float8 NOT NULL, active boolean NOT NULL, role text NOT NULL)",
    },
        \\vf_users.name: Zig []const u8 vs pg nullable column (make the field optional or the column NOT NULL)
        \\vf_users.age: Zig ?u8 vs pg NOT NULL column
    );
}

test "verify: the primary key must be S.primary_key alone" {
    const cols = "id bigint NOT NULL, name text NOT NULL, age smallint, score float8 NOT NULL, active boolean NOT NULL, role text NOT NULL";
    try expectDiagnostics(&.{"CREATE TABLE vf_users (" ++ cols ++ ")"}, "vf_users: no primary key, expected (id)");
    try expectDiagnostics(&.{"CREATE TABLE vf_users (" ++ cols ++ ", PRIMARY KEY (name))"}, "vf_users: primary key is (name), expected (id)");
    try expectDiagnostics(&.{"CREATE TABLE vf_users (" ++ cols ++ ", PRIMARY KEY (id, name))"}, "vf_users: primary key is (id, name), expected (id)");
}

test "verify: a missing table is one mismatch" {
    try expectDiagnostics(&.{}, "vf_users: no such table");
}

test "verify: one Diagnostics collects several calls" {
    var g = try open(good_table);
    defer close(&g);
    const Bad = zom.Schema(struct { id: u32, nickname: []const u8 }, "vf_users", .id, .{});

    var diag: zom_pg.Diagnostics = .init(testing.allocator);
    defer diag.deinit();
    try g.verify(Users, &diag);
    try testing.expectError(error.SchemaMismatch, g.verify(Bad, &diag));
    try testing.expectError(error.SchemaMismatch, g.verify(Bad, &diag));
    try testing.expectEqual(2, diag.mismatches.items.len);
    try testing.expectEqualStrings("nickname", diag.mismatches.items[0].column.?);
    try testing.expect(diag.mismatches.items[0].problem == .missing_column);
}

test "verify: works inside a transaction" {
    var g = try open(good_table);
    defer close(&g);
    try g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try tx.verify(Users, null);
        }
    }.f);
}
