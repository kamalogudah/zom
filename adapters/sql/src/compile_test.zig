//! Snapshot tests: each query feature, compiled for Postgres and SQLite,
//! against the expected SQL and parameter list.

const std = @import("std");
const zom = @import("zom");
const zom_sql = @import("root.zig");
const testing = std.testing;
const Value = zom.Value;
const Dialect = zom_sql.Dialect;

const Role = enum { admin, member };
const User = struct {
    id: u32,
    name: []const u8,
    age: u8,
    role: Role = .member,
    deleted_at: ?i64 = null,
};
const Q = zom.Query(User);
const q: Q = .{};

/// Everything before WHERE, which every snapshot below shares.
const select_all =
    \\SELECT "id", "name", "age", "role", "deleted_at" FROM "users"
;

/// Compiles `query` for both dialects and checks the SQL after
/// `select_all` and the parameters, which are the same for both.
fn expectSql(query: Q, pg: []const u8, lite: []const u8, params: []const Value) !void {
    try expectDialect(.postgres, query, pg, params);
    try expectDialect(.sqlite, query, lite, params);
}

fn expectDialect(comptime dialect: Dialect, query: Q, rest: []const u8, params: []const Value) !void {
    const compiled = try zom_sql.compileSelect(dialect, User, testing.allocator, "users", query);
    defer compiled.deinit(testing.allocator);
    const expected = try std.mem.concat(testing.allocator, u8, &.{ select_all, rest });
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, compiled.sql);
    try testing.expectEqualDeep(params, compiled.params);
}

fn paged(query: Q, limit: ?usize, offset: usize) Q {
    var next = query;
    next.limit = limit;
    next.offset = offset;
    return next;
}

fn int(v: i64) Value {
    return .{ .int = v };
}

fn str(v: []const u8) Value {
    return .{ .string = v };
}

test "no query: every column, nothing else" {
    try expectSql(q, "", "", &.{});
}

test "comparisons bind one parameter each" {
    try expectSql(
        q.where(.id, .eq, 1).where(.id, .neq, 2).where(.age, .lt, 3).where(.age, .lte, 4)
            .where(.age, .gt, 5).where(.age, .gte, 6).where(.role, .eq, .admin),
        \\ WHERE "id" = $1 AND "id" <> $2 AND "age" < $3 AND "age" <= $4 AND "age" > $5 AND "age" >= $6 AND "role" = $7
    ,
        \\ WHERE "id" = ? AND "id" <> ? AND "age" < ? AND "age" <= ? AND "age" > ? AND "age" >= ? AND "role" = ?
    ,
        &.{ int(1), int(2), int(3), int(4), int(5), int(6), str("admin") },
    );
}

test "IS NULL and IS NOT NULL, including eq / neq null" {
    try expectSql(
        q.where(.deleted_at, .is_null, {}).where(.deleted_at, .is_not_null, {})
            .where(.deleted_at, .eq, null).where(.deleted_at, .neq, null),
        \\ WHERE "deleted_at" IS NULL AND "deleted_at" IS NOT NULL AND "deleted_at" IS NULL AND "deleted_at" IS NOT NULL
    ,
        \\ WHERE "deleted_at" IS NULL AND "deleted_at" IS NOT NULL AND "deleted_at" IS NULL AND "deleted_at" IS NOT NULL
    ,
        &.{},
    );
}

test "ordering against null is an error, not a query that never matches" {
    try testing.expectError(
        error.InvalidNullComparison,
        zom_sql.compileSelect(.postgres, User, testing.allocator, "users", q.where(.deleted_at, .lt, null)),
    );
}

test "IN and NOT IN bind each value, nulls included" {
    try expectSql(
        q.where(.id, .in, .{ 1, 2, 3 }).where(.role, .not_in, .{.admin}).where(.deleted_at, .in, .{ 5, null }),
        \\ WHERE "id" IN ($1, $2, $3) AND "role" NOT IN ($4) AND "deleted_at" IN ($5, $6)
    ,
        \\ WHERE "id" IN (?, ?, ?) AND "role" NOT IN (?) AND "deleted_at" IN (?, ?)
    ,
        &.{ int(1), int(2), int(3), str("admin"), int(5), .null },
    );
}

test "whereIn with a runtime slice" {
    const ids = [_]u32{ 7, 8 };
    try expectSql(
        q.whereIn(.id, &ids).whereNotIn(.id, @as([]const u32, &.{9})),
        \\ WHERE "id" IN ($1, $2) AND "id" NOT IN ($3)
    ,
        \\ WHERE "id" IN (?, ?) AND "id" NOT IN (?)
    ,
        &.{ int(7), int(8), int(9) },
    );
}

test "an empty IN is 1=0 and an empty NOT IN is 1=1" {
    const none: []const u32 = &.{};
    try expectSql(
        q.whereIn(.id, none).whereNotIn(.id, none),
        \\ WHERE 1=0 AND 1=1
    ,
        \\ WHERE 1=0 AND 1=1
    ,
        &.{},
    );
}

test "an empty IN on a nullable attribute stays unknown for null, as in memory" {
    // NOT (1=0) would be true for a null deleted_at; memory says unknown,
    // so the row must match neither the filter nor its negation.
    const none: []const i64 = &.{};
    try expectSql(
        q.whereIn(.deleted_at, none).whereNotIn(.deleted_at, none).whereNot(.{ .deleted_at, .in, none }),
        \\ WHERE ("deleted_at" IS NULL AND NULL) AND ("deleted_at" IS NOT NULL OR NULL) AND NOT (("deleted_at" IS NULL AND NULL))
    ,
        \\ WHERE ("deleted_at" IS NULL AND NULL) AND ("deleted_at" IS NOT NULL OR NULL) AND NOT (("deleted_at" IS NULL AND NULL))
    ,
        &.{},
    );
}

test "LIKE carries an ESCAPE clause; ILIKE is LOWER() LIKE LOWER() without it" {
    try expectSql(
        q.where(.name, .like, "A\\_%").where(.name, .ilike, "%kim%"),
        \\ WHERE "name" LIKE $1 ESCAPE '\' AND "name" ILIKE $2 ESCAPE '\'
    ,
        \\ WHERE "name" LIKE ? ESCAPE '\' AND LOWER("name") LIKE LOWER(?) ESCAPE '\'
    ,
        &.{ str("A\\_%"), str("%kim%") },
    );
}

test "BETWEEN binds both ends" {
    try expectSql(
        q.where(.age, .between, .{ 18, 30 }),
        \\ WHERE "age" BETWEEN $1 AND $2
    ,
        \\ WHERE "age" BETWEEN ? AND ?
    ,
        &.{ int(18), int(30) },
    );
}

test "AND / OR / NOT groups get parentheses, nested or not" {
    try expectSql(
        q.whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })
            .where(.deleted_at, .is_null, {})
            .whereNot(.{ .name, .eq, "x" })
            .whereNot(zom.any(.{ .{ .id, .eq, 1 }, zom.all(.{ .{ .id, .gt, 5 }, .{ .id, .lt, 9 } }) }))
            .whereNot(zom.not(.{ .age, .between, .{ 1, 2 } })),
        \\ WHERE ("age" > $1 OR "role" = $2) AND "deleted_at" IS NULL AND NOT ("name" = $3) AND NOT ("id" = $4 OR ("id" > $5 AND "id" < $6)) AND NOT (NOT ("age" BETWEEN $7 AND $8))
    ,
        \\ WHERE ("age" > ? OR "role" = ?) AND "deleted_at" IS NULL AND NOT ("name" = ?) AND NOT ("id" = ? OR ("id" > ? AND "id" < ?)) AND NOT (NOT ("age" BETWEEN ? AND ?))
    ,
        &.{ int(30), str("admin"), str("x"), int(1), int(5), int(9), int(1), int(2) },
    );
}

test "every op inside a group" {
    try expectSql(
        q.whereAny(.{
            .{ .id, .in, .{ 1, 2 } },
            .{ .name, .ilike, "a%" },
            .{ .age, .between, .{ 1, 9 } },
            .{ .deleted_at, .is_not_null, {} },
        }),
        \\ WHERE ("id" IN ($1, $2) OR "name" ILIKE $3 ESCAPE '\' OR "age" BETWEEN $4 AND $5 OR "deleted_at" IS NOT NULL)
    ,
        \\ WHERE ("id" IN (?, ?) OR LOWER("name") LIKE LOWER(?) ESCAPE '\' OR "age" BETWEEN ? AND ? OR "deleted_at" IS NOT NULL)
    ,
        &.{ int(1), int(2), str("a%"), int(1), int(9) },
    );
}

test "ORDER BY several keys; nullable keys put nulls where memory does" {
    try expectSql(
        q.order(.role, .asc).order(.deleted_at, .desc).order(.age, .desc).order(.deleted_at, .asc),
        \\ ORDER BY "role" ASC, "deleted_at" DESC NULLS FIRST, "age" DESC, "deleted_at" ASC NULLS LAST
    ,
        \\ ORDER BY "role" ASC, "deleted_at" DESC NULLS FIRST, "age" DESC, "deleted_at" ASC NULLS LAST
    ,
        &.{},
    );
    try expectSql(q.order(.id, .asc).reorder(.{}), "", "", &.{});
}

test "LIMIT and OFFSET; SQLite needs a LIMIT before a bare OFFSET" {
    try expectSql(paged(q.where(.age, .gte, 18).order(.name, .desc), 10, 20),
        \\ WHERE "age" >= $1 ORDER BY "name" DESC LIMIT 10 OFFSET 20
    ,
        \\ WHERE "age" >= ? ORDER BY "name" DESC LIMIT 10 OFFSET 20
    , &.{int(18)});
    try expectSql(paged(q, 5, 0), " LIMIT 5", " LIMIT 5", &.{});
    try expectSql(paged(q, null, 5), " OFFSET 5", " LIMIT -1 OFFSET 5", &.{});
}

test "a limit or offset past bigint is clamped to its largest value" {
    const max = std.math.maxInt(usize);
    try expectSql(
        paged(q, max, max),
        " LIMIT 9223372036854775807 OFFSET 9223372036854775807",
        " LIMIT 9223372036854775807 OFFSET 9223372036854775807",
        &.{},
    );
}

test "projections read only the selected columns" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);
    const users = try Users.init(&gw);

    // Filters and orders may use columns that were not selected.
    const rel = users.where(.age, .gte, 18).select(.{ .name, .id }).order(.deleted_at, .asc);
    inline for (.{ Dialect.postgres, Dialect.sqlite }, .{
        \\SELECT "name", "id" FROM "users" WHERE "age" >= $1 ORDER BY "deleted_at" ASC NULLS LAST
        ,
        \\SELECT "name", "id" FROM "users" WHERE "age" >= ? ORDER BY "deleted_at" ASC NULLS LAST
    }) |dialect, expected| {
        const compiled = try zom_sql.compileRelation(dialect, testing.allocator, rel);
        defer compiled.deinit(testing.allocator);
        try testing.expectEqualStrings(expected, compiled.sql);
        try testing.expectEqualDeep(@as([]const Value, &.{int(18)}), compiled.params);
    }

    // Without select, a relation reads every column.
    const all = try zom_sql.compileRelation(.postgres, testing.allocator, users);
    defer all.deinit(testing.allocator);
    try testing.expectEqualStrings(select_all, all.sql);

    // compileProjected takes the narrower struct directly.
    const P = zom.Project(User, .{.age});
    const p = try zom_sql.compileProjected(.sqlite, User, P, testing.allocator, "users", q.where(.id, .eq, 1));
    defer p.deinit(testing.allocator);
    try testing.expectEqualStrings(
        \\SELECT "age" FROM "users" WHERE "id" = ?
    , p.sql);
}

test "identifiers are quoted: reserved words, mixed case, embedded quotes" {
    const Row = struct { id: u32, order: u32, createdAt: i64 };
    const query = zom.Query(Row){};
    const pg = try zom_sql.compileSelect(.postgres, Row, testing.allocator, "user", query.where(.order, .eq, 1).order(.createdAt, .asc));
    defer pg.deinit(testing.allocator);
    try testing.expectEqualStrings(
        \\SELECT "id", "order", "createdAt" FROM "user" WHERE "order" = $1 ORDER BY "createdAt" ASC
    , pg.sql);

    const hostile = try zom_sql.compileSelect(.sqlite, Row, testing.allocator, "users\"; DROP TABLE users; --", query);
    defer hostile.deinit(testing.allocator);
    try testing.expectEqualStrings(
        \\SELECT "id", "order", "createdAt" FROM "users""; DROP TABLE users; --"
    , hostile.sql);
}

/// A MySQL-like dialect, to exercise the fields postgres and sqlite leave
/// at their defaults.
const backtick: Dialect = .{
    .placeholder = .question,
    .quote = '`',
    .returning = false,
    .ilike = false,
    .nulls_order = false,
    .limit_all = "18446744073709551615",
    .max_params = 65535,
};

test "a dialect's quote character, and nulls ordered without NULLS LAST" {
    const compiled = try zom_sql.compileSelect(backtick, User, testing.allocator, "my`table", paged(q.where(.name, .eq, "a").order(.deleted_at, .asc).order(.deleted_at, .desc).order(.id, .desc), null, 3));
    defer compiled.deinit(testing.allocator);
    try testing.expectEqualStrings(
        "SELECT `id`, `name`, `age`, `role`, `deleted_at` FROM `my``table` WHERE `name` = ? " ++
            "ORDER BY `deleted_at` IS NULL ASC, `deleted_at` ASC, `deleted_at` IS NULL DESC, `deleted_at` DESC, `id` DESC " ++
            "LIMIT 18446744073709551615 OFFSET 3",
        compiled.sql,
    );
}

test "writeIdent doubles embedded quotes" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try zom_sql.writeIdent(.postgres, &w, "a\"b\"");
    try testing.expectEqualStrings("\"a\"\"b\"\"\"", w.buffered());
}

test "writeSelect renders into any writer" {
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var params: zom_sql.Params = .{ .allocator = testing.allocator };
    defer params.deinit();
    const query = q.where(.id, .eq, 1);
    try zom_sql.writeSelect(.postgres, User, zom.Project(User, .{.id}), &w, &params, "users", &query);
    try testing.expectEqualStrings(
        \\SELECT "id" FROM "users" WHERE "id" = $1
    , w.buffered());
    try testing.expectEqual(1, params.list.items.len);

    // A writer that runs out of room fails with its own error.
    var tiny: [8]u8 = undefined;
    var short: std.Io.Writer = .fixed(&tiny);
    try testing.expectError(error.WriteFailed, zom_sql.writeSelect(.postgres, User, User, &short, &params, "users", &query));
}

test "running out of memory frees everything" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(a: std.mem.Allocator) !void {
            const c = try zom_sql.compileSelect(.sqlite, User, a, "users", q.where(.id, .in, .{ 1, 2 }).where(.name, .like, "a%"));
            c.deinit(a);
        }
    }.run, .{});
}

test "README: zom-sql" {
    const allocator = testing.allocator;
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway).init(&gw);

    // -- README: zom-sql (verbatim, minus the import) ----------------------
    const compiled = try zom_sql.compileRelation(.postgres, allocator, users.where(.age, .gte, 18).select(.{ .id, .name }));
    defer compiled.deinit(allocator);
    // compiled.sql:    SELECT "id", "name" FROM "users" WHERE "age" >= $1
    // compiled.params: .{ .{ .int = 18 } }

    try testing.expectEqualStrings(
        \\SELECT "id", "name" FROM "users" WHERE "age" >= $1
    , compiled.sql);
    try testing.expectEqualDeep(@as([]const Value, &.{int(18)}), compiled.params);
}

/// `query` with `per_group` set, as `combine` sends it to a dataset with
/// `supports.per_group_limit`.
fn perGroup(query: Q, field: Q.Field, limit: ?usize, offset: usize) Q {
    var next = paged(query, limit, offset);
    next.per_group = field;
    return next;
}

fn expectWhole(comptime dialect: Dialect, comptime Out: type, query: Q, expected: []const u8, params: []const Value) !void {
    const compiled = try zom_sql.compileProjected(dialect, User, Out, testing.allocator, "users", query);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqualStrings(expected, compiled.sql);
    try testing.expectEqualDeep(params, compiled.params);
}

const inner_all =
    \\SELECT "id", "name", "age", "role", "deleted_at" FROM (SELECT "id", "name", "age", "role", "deleted_at", ROW_NUMBER() OVER (PARTITION BY
;

test "per_group: ROW_NUMBER() per group in a derived table, filtered on the row number" {
    try expectWhole(.postgres, User, perGroup(q.where(.age, .gte, 18).order(.id, .desc), .role, 3, 1), inner_all ++
        \\ "role" ORDER BY "id" DESC) AS "zom_rn" FROM "users" WHERE "age" >= $1) AS "zom_paged" WHERE "zom_rn" > 1 AND "zom_rn" <= 4 ORDER BY "id" DESC
    , &.{int(18)});
    try expectWhole(.sqlite, User, perGroup(q.where(.age, .gte, 18).order(.id, .desc), .role, 3, 1), inner_all ++
        \\ "role" ORDER BY "id" DESC) AS "zom_rn" FROM "users" WHERE "age" >= ?) AS "zom_paged" WHERE "zom_rn" > 1 AND "zom_rn" <= 4 ORDER BY "id" DESC
    , &.{int(18)});
    // A limit alone, an offset alone, and no order.
    try expectWhole(.postgres, User, perGroup(q, .role, 2, 0), inner_all ++
        \\ "role") AS "zom_rn" FROM "users") AS "zom_paged" WHERE "zom_rn" <= 2
    , &.{});
    try expectWhole(.sqlite, User, perGroup(q.order(.age, .asc), .role, null, 2), inner_all ++
        \\ "role" ORDER BY "age" ASC) AS "zom_rn" FROM "users") AS "zom_paged" WHERE "zom_rn" > 2 ORDER BY "age" ASC
    , &.{});
}

test "per_group: without a limit or offset it is a plain select" {
    try expectSql(perGroup(q.order(.id, .asc), .role, null, 0),
        \\ ORDER BY "id" ASC
    ,
        \\ ORDER BY "id" ASC
    , &.{});
}

test "per_group: the bounds are clamped to bigint, and limit(0) keeps nothing" {
    const max = std.math.maxInt(usize);
    try expectWhole(.postgres, User, perGroup(q, .role, max, max), inner_all ++
        \\ "role") AS "zom_rn" FROM "users") AS "zom_paged" WHERE "zom_rn" > 9223372036854775807 AND "zom_rn" <= 9223372036854775807
    , &.{});
    try expectWhole(.postgres, User, perGroup(q, .role, 0, 0), inner_all ++
        \\ "role") AS "zom_rn" FROM "users") AS "zom_paged" WHERE "zom_rn" <= 0
    , &.{});
}

test "per_group: a projection keeps the outer columns, the order may use the others" {
    const P = zom.Project(User, .{.name});
    try expectWhole(.postgres, P, perGroup(q.order(.deleted_at, .desc), .age, 1, 0),
        \\SELECT "name" FROM (SELECT "id", "name", "age", "role", "deleted_at", ROW_NUMBER() OVER (PARTITION BY "age" ORDER BY "deleted_at" DESC NULLS FIRST) AS "zom_rn" FROM "users") AS "zom_paged" WHERE "zom_rn" <= 1 ORDER BY "deleted_at" DESC NULLS FIRST
    , &.{});
}
