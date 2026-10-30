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

const Counter = struct { id: u64, n: u64 };
const Counters = zom.Relation(zom.Schema(Counter, "counters", .id), zom.memory.Gateway);

test "u64 values above maxInt(i64) round-trip" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const counters = try Counters.init(&gw);

    const max = std.math.maxInt(u64);
    const big: u64 = std.math.maxInt(i64) + 1;
    _ = try counters.create(.{ .id = max, .n = 1 }).commit();
    _ = try counters.create(.{ .id = big, .n = 2 }).commit();
    _ = try counters.create(.{ .id = 1, .n = 3 }).commit();
    try testing.expectError(error.DuplicatePrimaryKey, counters.create(.{ .id = max, .n = 4 }).commit());

    try testing.expectEqual(@as(u64, 1), (try counters.where(.id, .eq, max).one(testing.allocator)).?.n);
    try testing.expectEqual(@as(usize, 2), counters.where(.id, .gt, std.math.maxInt(i64)).count());
    try testing.expectEqual(@as(usize, 3), counters.where(.id, .gte, 0).count());

    const rows = try counters.order(.id, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(u64, &.{ max, big, 1 }, &.{ rows[0].id, rows[1].id, rows[2].id });

    try testing.expectEqual(@as(usize, 1), try counters.byPk(big).update().set(.n, max).commit());
    try testing.expectEqual(max, (try counters.byPk(big).one(testing.allocator)).?.n);
}

test "int and uint values compare across variants" {
    try testing.expectEqual(std.math.Order.lt, zom.Value.order(.{ .int = -1 }, .{ .uint = 0 }).?);
    try testing.expectEqual(std.math.Order.gt, zom.Value.order(.{ .uint = 0 }, .{ .int = -1 }).?);
    try testing.expectEqual(std.math.Order.eq, zom.Value.order(.{ .int = 5 }, .{ .uint = 5 }).?);
    try testing.expectEqual(std.math.Order.lt, zom.Value.order(.{ .int = std.math.maxInt(i64) }, .{ .uint = std.math.maxInt(u64) }).?);
    try testing.expectEqual(std.math.Order.gt, zom.Value.order(.{ .uint = std.math.maxInt(u64) }, .{ .float = 1.0 }).?);
    try testing.expectEqual(std.math.Order.lt, zom.Value.order(.{ .float = -1.0 }, .{ .uint = 0 }).?);
}

test "u64 above maxInt(u32) on a u32 attribute is rejected" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    var id: u64 = std.math.maxInt(u64);
    _ = &id;
    try testing.expectError(error.ValueOutOfRange, users.byPk(1).update().set(.id, id).commit());
    try testing.expectEqual(@as(usize, 1), users.where(.id, .eq, 1).count());
}

const Contact = struct {
    id: u32,
    name: [:0]const u8,
    handle: []u8,
    nickname: ?[:0]const u8 = null,
};
const Contacts = zom.Relation(zom.Schema(Contact, "contacts", .id), zom.memory.Gateway);

test "every string type is copied on insert and update" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const contacts = try Contacts.init(&gw);

    const name = try testing.allocator.dupeZ(u8, "Achieng");
    defer testing.allocator.free(name);
    const handle = try testing.allocator.dupe(u8, "achieng");
    defer testing.allocator.free(handle);
    const nickname = try testing.allocator.dupeZ(u8, "Chi");
    defer testing.allocator.free(nickname);

    _ = try contacts.create(.{ .id = 1, .name = name, .handle = handle, .nickname = nickname }).commit();
    _ = try contacts.create(.{ .id = 2, .name = name, .handle = handle }).commit();
    // The allocator does not catch use-after-free, so clobber the buffers instead.
    @memset(name, 'x');
    @memset(handle, 'x');
    @memset(nickname, 'x');

    const first = (try contacts.byPk(1).one(testing.allocator)).?;
    try testing.expectEqualStrings("Achieng", first.name);
    try testing.expectEqual(@as(u8, 0), first.name[first.name.len]);
    try testing.expectEqualStrings("achieng", first.handle);
    try testing.expectEqualStrings("Chi", first.nickname.?);
    try testing.expectEqual(@as(u8, 0), first.nickname.?[first.nickname.?.len]);
    try testing.expectEqual(@as(?[:0]const u8, null), (try contacts.byPk(2).one(testing.allocator)).?.nickname);

    const renamed = try testing.allocator.dupe(u8, "Otieno");
    defer testing.allocator.free(renamed);
    try testing.expectEqual(@as(usize, 1), try contacts.byPk(2).update()
        .set(.name, renamed).set(.handle, renamed).set(.nickname, renamed).commit());
    @memset(renamed, 'x');

    const second = (try contacts.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("Otieno", second.name);
    try testing.expectEqual(@as(u8, 0), second.name[second.name.len]);
    try testing.expectEqualStrings("Otieno", second.handle);
    try testing.expectEqualStrings("Otieno", second.nickname.?);

    try testing.expectEqual(@as(usize, 1), try contacts.byPk(1).update().set(.nickname, null).commit());
    try testing.expectEqual(@as(?[:0]const u8, null), (try contacts.byPk(1).one(testing.allocator)).?.nickname);
}

const Priority = enum { low, medium, high };

const Task = struct {
    id: u32,
    priority: Priority,
    escalated_to: ?Priority = null,
};
const Tasks = zom.Relation(zom.Schema(Task, "tasks", .id), zom.memory.Gateway);

test "enums order and compare in declaration order" {
    var gw = zom.memory.Gateway.init(testing.allocator);
    defer gw.deinit();
    const tasks = try Tasks.init(&gw);
    _ = try tasks.create(.{ .id = 1, .priority = .high, .escalated_to = .high }).commit();
    _ = try tasks.create(.{ .id = 2, .priority = .low }).commit();
    _ = try tasks.create(.{ .id = 3, .priority = .medium, .escalated_to = .medium }).commit();

    const asc = try tasks.order(.priority, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(asc);
    try testing.expectEqualSlices(Priority, &.{ .low, .medium, .high }, &.{ asc[0].priority, asc[1].priority, asc[2].priority });

    const desc = try tasks.order(.priority, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expectEqualSlices(Priority, &.{ .high, .medium, .low }, &.{ desc[0].priority, desc[1].priority, desc[2].priority });

    const above_low = try tasks.where(.priority, .gt, .low).order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(above_low);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, &.{ above_low[0].id, above_low[1].id });
    try testing.expectEqual(@as(usize, 2), tasks.where(.priority, .lt, .high).count());
    try testing.expectEqual(@as(usize, 1), tasks.where(.priority, .eq, .medium).count());
    try testing.expectEqual(@as(usize, 2), tasks.where(.priority, .neq, .medium).count());

    // A runtime enum value goes through the same path as a literal.
    var p: Priority = .medium;
    _ = &p;
    try testing.expectEqual(@as(usize, 1), tasks.where(.priority, .gte, p).where(.priority, .lt, .high).count());

    // Optional enums keep the null rules: ordering never matches null,
    // and nulls sort last on asc, first on desc.
    try testing.expectEqual(@as(usize, 2), tasks.where(.escalated_to, .gt, .low).count());
    try testing.expectEqual(@as(usize, 1), tasks.where(.escalated_to, .gt, .medium).count());
    try testing.expectEqual(@as(usize, 1), tasks.where(.escalated_to, .eq, null).count());
    try testing.expectEqual(@as(usize, 2), tasks.where(.escalated_to, .neq, null).count());

    const esc_asc = try tasks.order(.escalated_to, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(esc_asc);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, &.{ esc_asc[0].id, esc_asc[1].id, esc_asc[2].id });

    const esc_desc = try tasks.order(.escalated_to, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(esc_desc);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 3 }, &.{ esc_desc[0].id, esc_desc[1].id, esc_desc[2].id });
}

fn updateUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var gw = zom.memory.Gateway.init(allocator);
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const before = try users.order(.id, .asc).toSlice(allocator);
    defer allocator.free(before);

    // Long enough that every copy needs a fresh arena buffer.
    const name = "n" ** 4096;
    const changed = users.update().set(.name, name).set(.email, name).commit() catch |err| {
        const after = try users.order(.id, .asc).toSlice(testing.allocator);
        defer testing.allocator.free(after);
        try testing.expectEqualDeep(before, after);
        return err;
    };
    try testing.expectEqual(@as(usize, 3), changed);
    try testing.expectEqual(@as(usize, 3), users.where(.name, .eq, name).where(.email, .eq, name).count());
}

test "an update that runs out of memory leaves the dataset unchanged" {
    try testing.checkAllAllocationFailures(testing.allocator, updateUnderAllocationFailure, .{});
}
