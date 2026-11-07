//! Snapshot tests for joined queries (`relation.join(.posts)`), rendered as
//! a correlated `WHERE EXISTS` semi-join and compiled
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
const select_users = "SELECT " ++ users_cols ++
    \\ FROM "users"
;
/// The correlated semi-join of `users.join(.posts)`, before its joined
/// filters (each ` AND ...`) and the closing parenthesis.
const exists_posts =
    \\EXISTS (SELECT 1 FROM "posts" WHERE "posts"."user_id" = "users"."id"
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

test "join(.posts): WHERE EXISTS with every column qualified" {
    try expectSql(.postgres, users.join(.posts), select_users ++ " WHERE " ++ exists_posts ++ ")", &.{});
}

test "whereJoined renders after the relation's own filters, on the joined table" {
    try expectSql(
        .postgres,
        users.where(.age, .gte, 18).join(.posts).whereJoined(.posts, .published, .eq, true)
            .whereJoined(.posts, .title, .like, "Zig%"),
        select_users ++ " WHERE \"users\".\"age\" >= $1 AND " ++ exists_posts ++
            \\ AND "posts"."published" = $2 AND "posts"."title" LIKE $3 ESCAPE '\')
        ,
        &.{ int(18), .{ .boolean = true }, .{ .string = "Zig%" } },
    );
    // The same placeholders in SQLite's style.
    try expectSql(
        .sqlite,
        users.join(.posts).whereJoined(.posts, .published, .eq, true).where(.age, .gte, 18),
        select_users ++ " WHERE \"users\".\"age\" >= ? AND " ++ exists_posts ++
            \\ AND "posts"."published" = ?)
        ,
        &.{ int(18), .{ .boolean = true } },
    );
}

test "joined filters only: WHERE starts with EXISTS" {
    try expectSql(
        .postgres,
        users.join(.posts).whereJoined(.posts, .id, .in, .{ 1, 2 }).whereJoined(.posts, .rating, .is_null, {}),
        select_users ++ " WHERE " ++ exists_posts ++
            \\ AND "posts"."id" IN ($1, $2) AND "posts"."rating" IS NULL)
        ,
        &.{ int(1), int(2) },
    );
}

test "an empty joined in list on a nullable column stays unknown for null" {
    const none: []const u8 = &.{};
    var rel = users.join(.posts);
    rel.query.join.?.addFilter(Post, .{ .field = .rating, .op = .in, .operand = .{ .many = .of(u8, none) } });
    try expectSql(.postgres, rel, select_users ++ " WHERE " ++ exists_posts ++
        \\ AND ("posts"."rating" IS NULL AND NULL))
    , &.{});
}

test "a runtime IN list on the joined table binds one placeholder per value" {
    const ids = [_]u32{ 3, 5, 8 };
    try expectSql(
        .postgres,
        users.where(.age, .gt, 20).join(.posts).whereJoinedIn(.posts, .id, &ids).whereJoinedNotIn(.posts, .user_id, ids[0..1]),
        select_users ++ " WHERE \"users\".\"age\" > $1 AND " ++ exists_posts ++
            \\ AND "posts"."id" IN ($2, $3, $4) AND "posts"."user_id" NOT IN ($5))
        ,
        &.{ int(20), int(3), int(5), int(8), int(3) },
    );
    // An empty runtime list renders like an empty tuple would.
    const none: []const u32 = &.{};
    try expectSql(.postgres, users.join(.posts).whereJoinedIn(.posts, .id, none), select_users ++ " WHERE " ++ exists_posts ++
        \\ AND 1=0)
    , &.{});
}

test "whereJoinedAny / whereJoinedNot render as groups on the joined table" {
    try expectSql(
        .postgres,
        users.join(.posts).whereJoinedAny(.posts, .{ .{ .published, .eq, true }, .{ .rating, .gte, 4 } }),
        select_users ++ " WHERE " ++ exists_posts ++
            \\ AND ("posts"."published" = $1 OR "posts"."rating" >= $2))
        ,
        &.{ .{ .boolean = true }, int(4) },
    );
    // Groups of both tuples, nested groups, NOT and a runtime list, AND-ed
    // in the order they were added: the query's own first, then the join's
    // inside the subquery.
    const ids = [_]u32{ 7, 9 };
    try expectSql(
        .postgres,
        users.join(.posts)
            .whereJoined(.posts, .title, .like, "Zig%")
            .whereJoinedAny(.posts, .{ zom.all(.{ .{ .published, .eq, true }, .{ .rating, .is_null, {} } }), .{ .id, .in, ids[0..] } })
            .whereJoinedNot(.posts, .{ .published, .eq, false })
            .whereJoinedNot(.posts, zom.any(.{ .{ .rating, .lt, 2 }, .{ .title, .eq, "x" } }))
            .whereAny(.{ .{ .age, .lt, 3 }, .{ .name, .eq, "y" } }),
        select_users ++ " WHERE (\"users\".\"age\" < $1 OR \"users\".\"name\" = $2) AND " ++ exists_posts ++
            \\ AND "posts"."title" LIKE $3 ESCAPE '\' AND (("posts"."published" = $4 AND "posts"."rating" IS NULL) OR "posts"."id" IN ($5, $6)) AND NOT ("posts"."published" = $7) AND NOT ("posts"."rating" < $8 OR "posts"."title" = $9))
        ,
        &.{ int(3), .{ .string = "y" }, .{ .string = "Zig%" }, .{ .boolean = true }, int(7), int(9), .{ .boolean = false }, int(2), .{ .string = "x" } },
    );
    // On a self-join, the group uses the alias.
    try expectSql(
        .sqlite,
        users.join(.manager).whereJoinedAny(.manager, .{ .{ .age, .gt, 50 }, .{ .name, .eq, "Boss" } }),
        select_users ++
            \\ WHERE EXISTS (SELECT 1 FROM "users" AS "manager" WHERE "manager"."id" = "users"."manager_id" AND ("manager"."age" > ? OR "manager"."name" = ?))
        ,
        &.{ int(50), .{ .string = "Boss" } },
    );
}

test "groups, order and paging on a joined select are qualified too" {
    try expectSql(
        .postgres,
        users.join(.posts).whereNot(.{ .name, .eq, "x" }).whereAny(.{ .{ .age, .lt, 3 }, .{ .age, .is_null, {} } })
            .order(.age, .desc).order(.id, .asc).limit(10).offset(20),
        select_users ++
            \\ WHERE NOT ("users"."name" = $1) AND ("users"."age" < $2 OR "users"."age" IS NULL) AND EXISTS (SELECT 1 FROM "posts" WHERE "posts"."user_id" = "users"."id") ORDER BY "users"."age" DESC NULLS FIRST, "users"."id" ASC LIMIT 10 OFFSET 20
        ,
        &.{ .{ .string = "x" }, int(3) },
    );
}

test "without NULLS LAST, a joined select orders by its IS NULL key directly" {
    const no_nulls_order: Dialect = .{ .placeholder = .question, .returning = false, .ilike = false, .nulls_order = false, .max_params = 999 };
    try expectSql(
        no_nulls_order,
        users.join(.posts).order(.age, .asc).limit(3),
        select_users ++ " WHERE " ++ exists_posts ++
            \\) ORDER BY "users"."age" IS NULL ASC, "users"."age" ASC LIMIT 3
        ,
        &.{},
    );
}

test "a projection selects its own columns, with no derived table" {
    try expectSql(
        .postgres,
        users.select(.{ .name, .age }).join(.posts).whereJoined(.posts, .published, .eq, true).order(.name, .asc).limit(5),
        \\SELECT "users"."name", "users"."age" FROM "users" WHERE 
    ++ exists_posts ++
        \\ AND "posts"."published" = $1) ORDER BY "users"."name" ASC LIMIT 5
    ,
        &.{.{ .boolean = true }},
    );
}

test "belongsTo: posts.join(.author) joins on the post's foreign key" {
    try expectSql(
        .postgres,
        posts.join(.author).whereJoined(.author, .name, .eq, "Achieng"),
        \\SELECT "posts"."id", "posts"."user_id", "posts"."title", "posts"."published", "posts"."rating" FROM "posts" WHERE EXISTS (SELECT 1 FROM "users" WHERE "users"."id" = "posts"."user_id" AND "users"."name" = $1)
    ,
        &.{.{ .string = "Achieng" }},
    );
}

test "a self-join aliases the joined table by the association's name" {
    try expectSql(
        .postgres,
        users.join(.manager).whereJoined(.manager, .age, .gt, 50),
        select_users ++
            \\ WHERE EXISTS (SELECT 1 FROM "users" AS "manager" WHERE "manager"."id" = "users"."manager_id" AND "manager"."age" > $1)
        ,
        &.{int(50)},
    );
}

test "a joined lt null is InvalidNullComparison, like an unjoined one" {
    const rel = users.join(.posts).whereJoined(.posts, .rating, .lt, null);
    try testing.expectError(error.InvalidNullComparison, zom_sql.compileRelation(.postgres, testing.allocator, rel));
}

test "UPDATE and DELETE use the same correlated EXISTS as a joined select" {
    const q = users.join(.posts).whereJoined(.posts, .published, .eq, false).where(.id, .eq, 1).query;
    const deleted = try zom_sql.compileDelete(.postgres, User, testing.allocator, "users", q);
    defer deleted.deinit(testing.allocator);
    try testing.expectEqualStrings("DELETE FROM \"users\" WHERE \"users\".\"id\" = $1 AND EXISTS (SELECT 1 FROM \"posts\" WHERE \"posts\".\"user_id\" = \"users\".\"id\" AND \"posts\".\"published\" = $2)", deleted.sql);
    try testing.expectEqualDeep(&[_]Value{ int(1), .{ .boolean = false } }, deleted.params);
    const changes = [_]zom.Query(User).Change{.{ .field = .age, .value = int(1) }};
    const updated = try zom_sql.compileUpdate(.postgres, User, testing.allocator, "users", q, &changes);
    defer updated.deinit(testing.allocator);
    try testing.expectEqualStrings("UPDATE \"users\" SET \"age\" = $1 WHERE \"users\".\"id\" = $2 AND EXISTS (SELECT 1 FROM \"posts\" WHERE \"posts\".\"user_id\" = \"users\".\"id\" AND \"posts\".\"published\" = $3)", updated.sql);
    try testing.expectEqualDeep(&[_]Value{ int(1), int(1), .{ .boolean = false } }, updated.params);

    const any_post = try zom_sql.compileDelete(.postgres, User, testing.allocator, "users", users.join(.posts).query);
    defer any_post.deinit(testing.allocator);
    try testing.expectEqualStrings("DELETE FROM \"users\" WHERE EXISTS (SELECT 1 FROM \"posts\" WHERE \"posts\".\"user_id\" = \"users\".\"id\")", any_post.sql);

    const self_join = try zom_sql.compileDelete(.postgres, User, testing.allocator, "users", users.join(.manager).whereJoined(.manager, .age, .gt, 50).query);
    defer self_join.deinit(testing.allocator);
    try testing.expectEqualStrings("DELETE FROM \"users\" WHERE EXISTS (SELECT 1 FROM \"users\" AS \"manager\" WHERE \"manager\".\"id\" = \"users\".\"manager_id\" AND \"manager\".\"age\" > $1)", self_join.sql);
}

test "unjoined selects are unchanged: no qualification" {
    try expectSql(.postgres, users.where(.age, .gt, 1),
        \\SELECT "id", "name", "age", "manager_id" FROM "users" WHERE "age" > $1
    , &.{int(1)});
}
