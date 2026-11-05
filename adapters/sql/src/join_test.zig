//! Snapshot tests for joined selects (`relation.join(.posts)`), compiled
//! through `compileRelation` from relations like application code builds
//! them. The memory gateway only provides the relation types; nothing is
//! read.

const std = @import("std");
const zom = @import("zom");
const zom_sql = @import("root.zig");
const testing = std.testing;
const Value = zom.Value;
const Dialect = zom_sql.Dialect;

const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    manager_id: ?u32 = null,
};
const Post = struct {
    id: u32,
    user_id: u32,
    title: []const u8,
    published: bool,
    rating: ?u8 = null,
};

const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
        pub const manager = zom.belongsTo(UserSchema, .manager_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
    },
});

const G = zom.memory.Gateway;
const Users = zom.Relation(UserSchema, G);
const Posts = zom.Relation(PostSchema, G);

/// Relations over a dataset pointer that is never read.
const users: Users = .{ .dataset = undefined };
const posts: Posts = .{ .dataset = undefined };

const users_cols =
    \\"users"."id", "users"."name", "users"."age", "users"."manager_id"
;
const users_join_posts = "SELECT DISTINCT " ++ users_cols ++
    \\ FROM "users" INNER JOIN "posts" ON "posts"."user_id" = "users"."id"
;

fn expectSql(comptime dialect: Dialect, relation: anytype, sql: []const u8, params: []const Value) !void {
    const compiled = try zom_sql.compileRelation(dialect, testing.allocator, relation);
    defer compiled.deinit(testing.allocator);
    try testing.expectEqualStrings(sql, compiled.sql);
    try testing.expectEqualDeep(params, compiled.params);
}

fn int(v: i64) Value {
    return .{ .int = v };
}

test "join(.posts): SELECT DISTINCT with every column qualified" {
    try expectSql(.postgres, users.join(.posts), users_join_posts, &.{});
}

test "whereJoined renders after the relation's own filters, on the joined table" {
    try expectSql(
        .postgres,
        users.where(.age, .gte, 18).join(.posts).whereJoined(.posts, .published, .eq, true)
            .whereJoined(.posts, .title, .like, "Zig%"),
        users_join_posts ++
            \\ WHERE "users"."age" >= $1 AND "posts"."published" = $2 AND "posts"."title" LIKE $3 ESCAPE '\'
        ,
        &.{ int(18), .{ .boolean = true }, .{ .string = "Zig%" } },
    );
    // The same placeholders in SQLite's style.
    try expectSql(
        .sqlite,
        users.join(.posts).whereJoined(.posts, .published, .eq, true).where(.age, .gte, 18),
        users_join_posts ++
            \\ WHERE "users"."age" >= ? AND "posts"."published" = ?
        ,
        &.{ int(18), .{ .boolean = true } },
    );
}

test "joined filters only: WHERE starts with them" {
    try expectSql(
        .postgres,
        users.join(.posts).whereJoined(.posts, .id, .in, .{ 1, 2 }).whereJoined(.posts, .rating, .is_null, {}),
        users_join_posts ++
            \\ WHERE "posts"."id" IN ($1, $2) AND "posts"."rating" IS NULL
        ,
        &.{ int(1), int(2) },
    );
}

test "an empty joined in list on a nullable column stays unknown for null" {
    const none: []const u8 = &.{};
    var rel = users.join(.posts);
    rel.query.join.?.addFilter(Post, .{ .field = .rating, .op = .in, .operand = .{ .many = .of(u8, none) } });
    try expectSql(.postgres, rel, users_join_posts ++
        \\ WHERE ("posts"."rating" IS NULL AND NULL)
    , &.{});
}

test "groups, order and paging on a joined select are qualified too" {
    try expectSql(
        .postgres,
        users.join(.posts).whereNot(.{ .name, .eq, "x" }).whereAny(.{ .{ .age, .lt, 3 }, .{ .age, .is_null, {} } })
            .order(.age, .desc).order(.id, .asc).limit(10).offset(20),
        users_join_posts ++
            \\ WHERE NOT ("users"."name" = $1) AND ("users"."age" < $2 OR "users"."age" IS NULL) ORDER BY "users"."age" DESC NULLS FIRST, "users"."id" ASC LIMIT 10 OFFSET 20
        ,
        &.{ .{ .string = "x" }, int(3) },
    );
}

test "without NULLS LAST, ordering moves outside DISTINCT into a derived table" {
    const no_nulls_order: Dialect = .{ .placeholder = .question, .returning = false, .ilike = false, .nulls_order = false, .max_params = 999 };
    try expectSql(
        no_nulls_order,
        users.join(.posts).order(.age, .asc).limit(3),
        "SELECT " ++ users_cols ++ " FROM (" ++ users_join_posts ++
            \\) AS "users" ORDER BY "users"."age" IS NULL ASC, "users"."age" ASC LIMIT 3
        ,
        &.{},
    );
    // Unordered, it stays one SELECT DISTINCT.
    try expectSql(no_nulls_order, users.join(.posts), users_join_posts, &.{});
}

test "a projection reads from DISTINCT over every column, in a derived table" {
    try expectSql(
        .postgres,
        users.select(.{ .name, .age }).join(.posts).whereJoined(.posts, .published, .eq, true).order(.name, .asc).limit(5),
        \\SELECT "users"."name", "users"."age" FROM (
    ++ users_join_posts ++
        \\ WHERE "posts"."published" = $1) AS "users" ORDER BY "users"."name" ASC LIMIT 5
    ,
        &.{.{ .boolean = true }},
    );
}

test "belongsTo: posts.join(.author) joins on the post's foreign key" {
    try expectSql(
        .postgres,
        posts.join(.author).whereJoined(.author, .name, .eq, "Achieng"),
        \\SELECT DISTINCT "posts"."id", "posts"."user_id", "posts"."title", "posts"."published", "posts"."rating" FROM "posts" INNER JOIN "users" ON "users"."id" = "posts"."user_id" WHERE "users"."name" = $1
    ,
        &.{.{ .string = "Achieng" }},
    );
}

test "a self-join aliases the joined table by the association's name" {
    try expectSql(
        .postgres,
        users.join(.manager).whereJoined(.manager, .age, .gt, 50),
        "SELECT DISTINCT " ++ users_cols ++
            \\ FROM "users" INNER JOIN "users" AS "manager" ON "manager"."id" = "users"."manager_id" WHERE "manager"."age" > $1
        ,
        &.{int(50)},
    );
}

test "a joined lt null is InvalidNullComparison, like an unjoined one" {
    const rel = users.join(.posts).whereJoined(.posts, .rating, .lt, null);
    try testing.expectError(error.InvalidNullComparison, zom_sql.compileRelation(.postgres, testing.allocator, rel));
}

test "UPDATE and DELETE refuse a joined query" {
    const q = users.join(.posts).where(.id, .eq, 1).query;
    try testing.expectError(error.JoinedWrite, zom_sql.compileDelete(.postgres, User, testing.allocator, "users", q));
    const changes = [_]zom.Query(User).Change{.{ .field = .age, .value = int(1) }};
    try testing.expectError(error.JoinedWrite, zom_sql.compileUpdate(.postgres, User, testing.allocator, "users", q, &changes));
}

test "unjoined selects are unchanged: no qualification" {
    try expectSql(.postgres, users.where(.age, .gt, 1),
        \\SELECT "id", "name", "age", "manager_id" FROM "users" WHERE "age" > $1
    , &.{int(1)});
}
