//! Snapshot tests for INSERT, UPDATE and DELETE, in each dialect, against
//! the expected SQL and parameter list.

const std = @import("std");
const zom = @import("zom");
const zom_sql = @import("root.zig");
const testing = std.testing;
const Value = zom.Value;
const Dialect = zom_sql.Dialect;
const Compiled = zom_sql.Compiled;

const Role = enum { admin, member };
const User = struct {
    id: u32,
    name: []const u8,
    role: Role = .member,
    deleted_at: ?i64 = null,
};
const Q = zom.Query(User);
const q: Q = .{};

/// A MySQL-like dialect: no RETURNING, backtick quotes.
const backtick: Dialect = .{
    .placeholder = .question,
    .quote = '`',
    .returning = false,
    .ilike = false,
    .nulls_order = false,
    .max_params = 65535,
};

fn int(v: i64) Value {
    return .{ .int = v };
}

fn str(v: []const u8) Value {
    return .{ .string = v };
}

fn expectCompiled(c: Compiled, sql: []const u8, params: []const Value) !void {
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings(sql, c.sql);
    try testing.expectEqualDeep(params, c.params);
}

const ada: User = .{ .id = 1, .name = "Ada", .role = .admin };
const bob: User = .{ .id = 2, .name = "Bob", .deleted_at = 1700000000 };

// -- INSERT -------------------------------------------------------------------

test "INSERT one row: every column, nulls and enum tag names bound, RETURNING where supported" {
    const a = testing.allocator;
    const params = &[_]Value{ int(1), str("Ada"), str("admin"), .null };
    try expectCompiled(
        try zom_sql.compileInsert(.postgres, User, a, "users", ada),
        \\INSERT INTO "users" ("id", "name", "role", "deleted_at") VALUES ($1, $2, $3, $4) RETURNING *
    ,
        params,
    );
    try expectCompiled(
        try zom_sql.compileInsert(.sqlite, User, a, "users", ada),
        \\INSERT INTO "users" ("id", "name", "role", "deleted_at") VALUES (?, ?, ?, ?) RETURNING *
    ,
        params,
    );
    try expectCompiled(
        try zom_sql.compileInsert(backtick, User, a, "users", ada),
        "INSERT INTO `users` (`id`, `name`, `role`, `deleted_at`) VALUES (?, ?, ?, ?)",
        params,
    );
}

test "INSERT many rows in one statement, numbering placeholders across rows" {
    const a = testing.allocator;
    const params = &[_]Value{ int(1), str("Ada"), str("admin"), .null, int(2), str("Bob"), str("member"), int(1700000000) };
    inline for (.{ Dialect.postgres, Dialect.sqlite }, .{
        \\INSERT INTO "users" ("id", "name", "role", "deleted_at") VALUES ($1, $2, $3, $4), ($5, $6, $7, $8) RETURNING *
        ,
        \\INSERT INTO "users" ("id", "name", "role", "deleted_at") VALUES (?, ?, ?, ?), (?, ?, ?, ?) RETURNING *
    }) |dialect, expected| {
        const batch = try zom_sql.compileInsertMany(dialect, User, a, "users", &.{ ada, bob });
        defer batch.deinit(a);
        try testing.expectEqual(1, batch.statements.len);
        try testing.expectEqualStrings(expected, batch.statements[0].sql);
        try testing.expectEqualDeep(@as([]const Value, params), batch.statements[0].params);
    }
}

test "INSERT many with no rows is no statements" {
    const batch = try zom_sql.compileInsertMany(.postgres, User, testing.allocator, "users", &.{});
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(0, batch.statements.len);
}

/// Room for two 4-field rows (9 / 4 = 2), so a third row needs a new statement.
const tight: Dialect = blk: {
    var d = Dialect.postgres;
    d.max_params = 9;
    break :blk d;
};

test "INSERT many splits rows across the parameter limit, each statement numbered from $1" {
    const a = testing.allocator;
    try testing.expectEqual(2, zom_sql.rowsPerStatement(tight, User));
    try testing.expectEqual(16383, zom_sql.rowsPerStatement(.postgres, User));
    try testing.expectEqual(8191, zom_sql.rowsPerStatement(.sqlite, User));

    var rows: [5]User = undefined;
    for (&rows, 0..) |*r, i| r.* = .{ .id = @intCast(i + 1), .name = "x" };

    const batch = try zom_sql.compileInsertMany(tight, User, a, "users", &rows);
    defer batch.deinit(a);
    try testing.expectEqual(3, batch.statements.len);

    const two =
        \\INSERT INTO "users" ("id", "name", "role", "deleted_at") VALUES ($1, $2, $3, $4), ($5, $6, $7, $8) RETURNING *
    ;
    try testing.expectEqualStrings(two, batch.statements[0].sql);
    try testing.expectEqualStrings(two, batch.statements[1].sql);
    try testing.expectEqualStrings(
        \\INSERT INTO "users" ("id", "name", "role", "deleted_at") VALUES ($1, $2, $3, $4) RETURNING *
    , batch.statements[2].sql);

    // Every row once, in order, and no statement past the limit.
    var next: i64 = 1;
    for (batch.statements) |s| {
        try testing.expect(s.params.len <= tight.max_params);
        var i: usize = 0;
        while (i < s.params.len) : (i += 4) {
            try testing.expectEqualDeep(&[_]Value{ int(next), str("x"), str("member"), .null }, s.params[i..][0..4]);
            next += 1;
        }
    }
    try testing.expectEqual(6, next);
}

test "INSERT many with an exact multiple of the limit leaves no empty statement" {
    var rows: [4]User = @splat(ada);
    const batch = try zom_sql.compileInsertMany(tight, User, testing.allocator, "users", &rows);
    defer batch.deinit(testing.allocator);
    try testing.expectEqual(2, batch.statements.len);
    for (batch.statements) |s| try testing.expectEqual(8, s.params.len);
}

test "INSERT of other value kinds: bool, float, u64 past i64, optional enum" {
    const Row = struct { ok: bool, score: f64, big: u64, tag: ?Role };
    try expectCompiled(
        try zom_sql.compileInsert(.sqlite, Row, testing.allocator, "t", .{ .ok = true, .score = 1.5, .big = std.math.maxInt(u64), .tag = .member }),
        \\INSERT INTO "t" ("ok", "score", "big", "tag") VALUES (?, ?, ?, ?) RETURNING *
    ,
        &.{ .{ .boolean = true }, .{ .float = 1.5 }, .{ .uint = std.math.maxInt(u64) }, str("member") },
    );
}

// -- UPDATE -------------------------------------------------------------------

fn changes(list: []const Q.Change) []const Q.Change {
    return list;
}

test "UPDATE: placeholders run on from SET into WHERE" {
    const a = testing.allocator;
    const set = changes(&.{
        .{ .field = .name, .value = str("Ada L.") },
        .{ .field = .role, .value = str("admin") },
        .{ .field = .deleted_at, .value = .null },
    });
    const where = q.where(.id, .eq, 1).whereAny(.{ .{ .role, .eq, .member }, .{ .deleted_at, .is_null, {} } });
    const params = &[_]Value{ str("Ada L."), str("admin"), .null, int(1), str("member") };
    try expectCompiled(
        try zom_sql.compileUpdate(.postgres, User, a, "users", where, set),
        \\UPDATE "users" SET "name" = $1, "role" = $2, "deleted_at" = $3 WHERE "id" = $4 AND ("role" = $5 OR "deleted_at" IS NULL)
    ,
        params,
    );
    try expectCompiled(
        try zom_sql.compileUpdate(.sqlite, User, a, "users", where, set),
        \\UPDATE "users" SET "name" = ?, "role" = ?, "deleted_at" = ? WHERE "id" = ? AND ("role" = ? OR "deleted_at" IS NULL)
    ,
        params,
    );
    try expectCompiled(
        try zom_sql.compileUpdate(backtick, User, a, "users", where, set),
        "UPDATE `users` SET `name` = ?, `role` = ?, `deleted_at` = ? WHERE `id` = ? AND (`role` = ? OR `deleted_at` IS NULL)",
        params,
    );
}

test "UPDATE: a field set twice takes its last value, as in memory" {
    try expectCompiled(
        try zom_sql.compileUpdate(.postgres, User, testing.allocator, "users", q.where(.id, .eq, 1), changes(&.{
            .{ .field = .name, .value = str("first") },
            .{ .field = .role, .value = str("admin") },
            .{ .field = .name, .value = str("last") },
        })),
        \\UPDATE "users" SET "role" = $1, "name" = $2 WHERE "id" = $3
    ,
        &.{ str("admin"), str("last"), int(1) },
    );
}

test "UPDATE ignores order, limit and offset, as the memory adapter does" {
    var where = q.where(.id, .gt, 1).order(.name, .asc);
    where.limit = 1;
    where.offset = 2;
    try expectCompiled(
        try zom_sql.compileUpdate(.postgres, User, testing.allocator, "users", where, changes(&.{.{ .field = .role, .value = str("admin") }})),
        \\UPDATE "users" SET "role" = $1 WHERE "id" > $2
    ,
        &.{ str("admin"), int(1) },
    );
}

test "UPDATE with no filters is refused unless query.all is set" {
    const a = testing.allocator;
    const set = changes(&.{.{ .field = .deleted_at, .value = int(5) }});
    try testing.expectError(error.UnboundedWrite, zom_sql.compileUpdate(.postgres, User, a, "users", q, set));
    // order and limit are not filters.
    var limited = q.order(.id, .asc);
    limited.limit = 1;
    try testing.expectError(error.UnboundedWrite, zom_sql.compileUpdate(.postgres, User, a, "users", limited, set));

    var every = q;
    every.all = true;
    try expectCompiled(
        try zom_sql.compileUpdate(.sqlite, User, a, "users", every, set),
        \\UPDATE "users" SET "deleted_at" = ?
    ,
        &.{int(5)},
    );
}

test "UPDATE with no changes is error.EmptyUpdate" {
    try testing.expectError(error.EmptyUpdate, zom_sql.compileUpdate(.postgres, User, testing.allocator, "users", q.where(.id, .eq, 1), &.{}));
}

test "UPDATE passes on WHERE errors" {
    try testing.expectError(error.InvalidNullComparison, zom_sql.compileUpdate(
        .postgres,
        User,
        testing.allocator,
        "users",
        q.where(.deleted_at, .gt, null),
        changes(&.{.{ .field = .name, .value = str("x") }}),
    ));
}

// -- DELETE -------------------------------------------------------------------

test "DELETE renders the WHERE in each dialect" {
    const a = testing.allocator;
    const where = q.where(.role, .eq, .member).where(.deleted_at, .is_not_null, {}).whereIn(.id, @as([]const u32, &.{ 3, 4 }));
    const params = &[_]Value{ str("member"), int(3), int(4) };
    try expectCompiled(
        try zom_sql.compileDelete(.postgres, User, a, "users", where),
        \\DELETE FROM "users" WHERE "role" = $1 AND "deleted_at" IS NOT NULL AND "id" IN ($2, $3)
    ,
        params,
    );
    try expectCompiled(
        try zom_sql.compileDelete(.sqlite, User, a, "users", where),
        \\DELETE FROM "users" WHERE "role" = ? AND "deleted_at" IS NOT NULL AND "id" IN (?, ?)
    ,
        params,
    );
    try expectCompiled(
        try zom_sql.compileDelete(backtick, User, a, "users", where),
        "DELETE FROM `users` WHERE `role` = ? AND `deleted_at` IS NOT NULL AND `id` IN (?, ?)",
        params,
    );
}

test "DELETE with no filters is error.UnboundedWrite unless query.all is set" {
    const a = testing.allocator;
    try testing.expectError(error.UnboundedWrite, zom_sql.compileDelete(.postgres, User, a, "users", q));
    try testing.expectError(error.UnboundedWrite, zom_sql.compileDelete(.sqlite, User, a, "users", q.order(.id, .desc)));

    var every = q;
    every.all = true;
    try expectCompiled(try zom_sql.compileDelete(.postgres, User, a, "users", every),
        \\DELETE FROM "users"
    , &.{});

    // With filters, `all` changes nothing.
    every = every.where(.id, .eq, 1);
    try expectCompiled(try zom_sql.compileDelete(.postgres, User, a, "users", every),
        \\DELETE FROM "users" WHERE "id" = $1
    , &.{int(1)});
}

test "an empty whereIn is still a filter: DELETE ... WHERE 1=0 deletes nothing" {
    try expectCompiled(
        try zom_sql.compileDelete(.postgres, User, testing.allocator, "users", q.whereIn(.id, @as([]const u32, &.{}))),
        \\DELETE FROM "users" WHERE 1=0
    ,
        &.{},
    );
}

test "a relation's delete and update queries compile with its schema's table" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);
    const users = try Users.init(&gw);

    const rel = users.byPk(7);
    try expectCompiled(try zom_sql.compileDelete(.postgres, User, testing.allocator, Users.schema.name, rel.query),
        \\DELETE FROM "users" WHERE "id" = $1
    , &.{int(7)});

    const cs = rel.update().set(.role, .admin).set(.deleted_at, null);
    try expectCompiled(
        try zom_sql.compileUpdate(.postgres, User, testing.allocator, Users.schema.name, rel.query, cs.changes[0..cs.change_count]),
        \\UPDATE "users" SET "role" = $1, "deleted_at" = $2 WHERE "id" = $3
    ,
        &.{ str("admin"), .null, int(7) },
    );
}

// -- writers and memory ------------------------------------------------------

test "write functions render into any writer and check before writing" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var params: zom_sql.Params = .{ .allocator = testing.allocator };
    defer params.deinit();

    try testing.expectError(error.UnboundedWrite, zom_sql.writeDelete(.postgres, User, &w, &params, "users", &q));
    try testing.expectError(error.EmptyUpdate, zom_sql.writeUpdate(.postgres, User, &w, &params, "users", &q, &.{}));
    try testing.expectEqual(0, w.buffered().len);

    try zom_sql.writeInsert(.sqlite, User, &w, &params, "users", &.{ada});
    try testing.expectEqualStrings(
        \\INSERT INTO "users" ("id", "name", "role", "deleted_at") VALUES (?, ?, ?, ?) RETURNING *
    , w.buffered());
    try testing.expectEqual(4, params.list.items.len);
}

test "running out of memory frees everything" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const rows = [_]User{ ada, bob, ada, bob, ada };
            const batch = try zom_sql.compileInsertMany(tight, User, a, "users", &rows);
            batch.deinit(a);
            const one = try zom_sql.compileInsert(.postgres, User, a, "users", bob);
            one.deinit(a);
            const up = try zom_sql.compileUpdate(.sqlite, User, a, "users", q.where(.id, .in, .{ 1, 2 }), &.{.{ .field = .name, .value = .{ .string = "z" } }});
            up.deinit(a);
            const del = try zom_sql.compileDelete(.postgres, User, a, "users", q.where(.name, .like, "a%"));
            del.deinit(a);
        }
    }.run, .{});
}
