const std = @import("std");
const zom = @import("root.zig");
const testing = std.testing;

const Role = enum { admin, member };

const UserTuple = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    age: u8,
    role: Role = .member,
    deleted_at: ?i64 = null,
};

const PostTuple = struct {
    id: u32,
    user_id: u32,
    title: []const u8,
    published: bool,
};

const Users = zom.Relation(zom.Schema(UserTuple, "users", .id), zom.memory.Gateway);
const Posts = zom.Relation(zom.Schema(PostTuple, "posts", .id), zom.memory.Gateway);

// Domain structs, decoupled from the tuples.
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const Author = struct { id: u32, full_name: []const u8, posts: []const Post = &.{} };

const AuthorMapper = zom.Mapper(UserTuple, Author, .{
    .renames = &.{.{ .from = "name", .to = "full_name" }},
});

fn seed(users: Users, posts: Posts) !void {
    _ = try users.create(.{ .id = 1, .name = "Achieng", .email = "achieng@example.com", .age = 31, .role = .admin }).commit();
    _ = try users.create(.{ .id = 2, .name = "Otieno", .email = "otieno@example.com", .age = 24 }).commit();
    _ = try users.create(.{ .id = 3, .name = "Wanjiru", .email = "wanjiru@example.com", .age = 42, .deleted_at = 1_700_000_000 }).commit();

    _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values", .published = true }).commit();
    _ = try posts.create(.{ .id = 11, .user_id = 1, .title = "Mappers, not models", .published = false }).commit();
    _ = try posts.create(.{ .id = 12, .user_id = 2, .title = "Comptime schemas", .published = true }).commit();
}

test "relations are chainable and lazy" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    const posts = try Posts.init(&gw);
    try seed(users, posts);

    const over_25 = users.where(.age, .gt, 25).order(.name, .asc);
    try testing.expectEqual(@as(usize, 2), over_25.count());

    const rows = try over_25.toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("Achieng", rows[0].name);
    try testing.expectEqualStrings("Wanjiru", rows[1].name);

    // The base relation is untouched by chaining.
    try testing.expectEqual(@as(usize, 3), users.count());

    const page = try users.order(.age, .desc).offset(1).limit(1).toSlice(testing.allocator);
    defer testing.allocator.free(page);
    try testing.expectEqualStrings("Achieng", page[0].name);
}

test "enum and null filters" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    try testing.expectEqual(@as(usize, 1), users.where(.role, .eq, .admin).count());
    try testing.expectEqual(@as(usize, 2), users.where(.deleted_at, .eq, null).count());
}

test "one, first and byPk" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const otieno = (try users.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("Otieno", otieno.name);
    try testing.expectEqual(@as(?UserTuple, null), try users.byPk(99).one(testing.allocator));
    try testing.expectError(error.MoreThanOneTuple, users.one(testing.allocator));
    try testing.expect((try users.first(testing.allocator)) != null);
}

fn promoteToAdmin(t: UserTuple) UserTuple {
    var next = t;
    next.role = .admin;
    return next;
}

test "create changeset with a map step" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);

    // Input buffer is reused right after commit; the dataset owns its copy.
    var name_buf = "Kamau".*;
    const stored = try users.create(.{ .id = 7, .name = &name_buf, .email = "kamau@example.com", .age = 29 })
        .map(promoteToAdmin)
        .commit();
    name_buf[0] = 'X';

    try testing.expectEqual(Role.admin, stored.role);
    const back = (try users.byPk(7).one(testing.allocator)).?;
    try testing.expectEqualStrings("Kamau", back.name);
}

test "update and delete" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const n = try users.byPk(2).update().set(.email, "o@example.com").set(.age, 25).commit();
    try testing.expectEqual(@as(usize, 1), n);
    const updated = (try users.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("o@example.com", updated.email);
    try testing.expectEqual(@as(u8, 25), updated.age);

    try testing.expectEqual(@as(usize, 1), users.where(.deleted_at, .neq, null).delete());
    try testing.expectEqual(@as(usize, 2), users.count());
}

test "map to entities and combine has-many" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    const posts = try Posts.init(&gw);
    try seed(users, posts);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // users.combine(:posts) in ROM terms.
    const authors = try users.where(.deleted_at, .eq, null).order(.id, .asc).mapWith(AuthorMapper, a);
    const author_posts = try posts.where(.published, .eq, true).order(.id, .asc).mapTo(Post, a);
    try zom.combineMany(.{ .into = "posts", .parent_key = "id", .child_key = "user_id" }, a, authors, author_posts);

    try testing.expectEqual(@as(usize, 2), authors.len);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
    try testing.expectEqual(@as(usize, 1), authors[0].posts.len);
    try testing.expectEqualStrings("Relations are values", authors[0].posts[0].title);
    try testing.expectEqualStrings("Comptime schemas", authors[1].posts[0].title);
}

test "sql compiler renders the same relation as a statement" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);

    const rel = users.where(.age, .gte, 18).where(.deleted_at, .eq, null).where(.role, .eq, .admin)
        .order(.name, .desc).limit(10).offset(20);
    const compiled = try zom.sql.compileSelect(UserTuple, testing.allocator, Users.schema.name, rel.query);
    defer compiled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "SELECT id, name, email, age, role, deleted_at FROM users WHERE age >= $1 AND deleted_at IS NULL AND role = $2 ORDER BY name DESC LIMIT 10 OFFSET 20",
        compiled.sql,
    );
    try testing.expectEqual(@as(usize, 2), compiled.params.len);
    try testing.expectEqual(@as(i64, 18), compiled.params[0].int);
    try testing.expectEqualStrings("admin", compiled.params[1].string);
}

test "order puts nulls last on asc and first on desc" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    for ([_]?i64{ 3, null, 1, 2 }, 1..) |deleted_at, id| {
        _ = try users.create(.{ .id = @intCast(id), .name = "u", .email = "u@example.com", .age = 30, .deleted_at = deleted_at }).commit();
    }

    const asc = try users.order(.deleted_at, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(asc);
    try testing.expectEqualSlices(u32, &.{ 3, 4, 1, 2 }, &.{ asc[0].id, asc[1].id, asc[2].id, asc[3].id });

    const desc = try users.order(.deleted_at, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 4, 3 }, &.{ desc[0].id, desc[1].id, desc[2].id, desc[3].id });
}

test "primary key is unique on create and update" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    try testing.expectError(
        error.DuplicatePrimaryKey,
        users.create(.{ .id = 1, .name = "Again", .email = "again@example.com", .age = 20 }).commit(),
    );
    try testing.expectError(error.DuplicatePrimaryKey, users.byPk(2).update().set(.id, 1).commit());
    try testing.expectError(error.DuplicatePrimaryKey, users.update().set(.id, 9).commit());

    // Moving one row to a free key is fine.
    try testing.expectEqual(@as(usize, 1), try users.byPk(2).update().set(.id, 9).commit());
    try testing.expectEqual(@as(usize, 3), users.count());
}

test "out of range runtime values are rejected without partial writes" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    var age: u32 = 300;
    _ = &age;
    try testing.expectError(
        error.ValueOutOfRange,
        users.update().set(.email, "x@example.com").set(.age, age).commit(),
    );
    const achieng = (try users.byPk(1).one(testing.allocator)).?;
    try testing.expectEqualStrings("achieng@example.com", achieng.email);
    try testing.expectEqual(@as(u8, 31), achieng.age);
}
