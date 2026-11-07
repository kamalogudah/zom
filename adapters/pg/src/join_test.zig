//! `relation.join` on zom-pg, against the memory gateway's semi-join: the
//! same `scenario`, generic over the gateway, must give the same rows on
//! both. The Postgres run is skipped unless `ZOM_PG_URL` is set (see
//! lint_test.zig), and drops and recreates the `pj_users` and `pj_posts`
//! tables.

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("root.zig");
const testing = std.testing;

const Role = enum { admin, member };

const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    role: Role,
};

const Post = struct {
    id: u32,
    user_id: ?u32,
    title: []const u8,
    published: bool,
    likes: u32,
};

const Users = zom.Schema(User, "pj_users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(Posts, .user_id);
    },
});
const Posts = zom.Schema(Post, "pj_posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(Users, .user_id);
    },
});

const create_users =
    \\CREATE TABLE pj_users (
    \\  id bigint PRIMARY KEY,
    \\  name text NOT NULL,
    \\  age smallint,
    \\  role text NOT NULL
    \\)
;
const create_posts =
    \\CREATE TABLE pj_posts (
    \\  id bigint PRIMARY KEY,
    \\  user_id bigint REFERENCES pj_users (id),
    \\  title text NOT NULL,
    \\  published boolean NOT NULL,
    \\  likes bigint NOT NULL
    \\)
;

const users_seed = [_]User{
    .{ .id = 1, .name = "Achieng", .age = 31, .role = .admin },
    .{ .id = 2, .name = "Otieno", .age = 24, .role = .member },
    .{ .id = 3, .name = "Wanjiru", .age = null, .role = .member },
    .{ .id = 4, .name = "Kamau", .age = 19, .role = .member },
};

/// Achieng: two posts, one published, three in all with many likes. Post
/// 15 belongs to nobody.
const posts_seed = [_]Post{
    .{ .id = 10, .user_id = 1, .title = "Relations are values", .published = true, .likes = 5 },
    .{ .id = 11, .user_id = 1, .title = "Mappers, not models", .published = false, .likes = 50 },
    .{ .id = 12, .user_id = 2, .title = "Comptime schemas", .published = true, .likes = 7 },
    .{ .id = 13, .user_id = 3, .title = "Draft", .published = false, .likes = 0 },
    .{ .id = 14, .user_id = 1, .title = "Zig and SQL", .published = true, .likes = 12 },
    .{ .id = 15, .user_id = null, .title = "Orphan", .published = true, .likes = 99 },
};

fn scenario(comptime G: type, gw: *G) !void {
    const a = testing.allocator;
    const users = try zom.Relation(Users, G).init(gw);
    const posts = try zom.Relation(Posts, G).init(gw);
    try testing.expectEqual(users_seed.len, try users.createMany(&users_seed).commit());
    try testing.expectEqual(posts_seed.len, try posts.createMany(&posts_seed).commit());

    // Each user with a post, once, however many posts they have.
    {
        const rows = try users.join(.posts).order(.id, .asc).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{ 1, 2, 3 }, rows);
        try testing.expectEqualStrings("Achieng", rows[0].name);
        try testing.expectEqual(null, rows[2].age);
    }
    try testing.expectEqual(3, try users.join(.posts).count());

    // The issue's example: users with at least one published post.
    {
        const rows = try users.join(.posts).whereJoined(.posts, .published, .eq, true).order(.id, .asc).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{ 1, 2 }, rows);
    }
    // Both joined filters hold for one post (#14), not just for some post each.
    {
        const rows = try users.join(.posts).whereJoined(.posts, .published, .eq, true)
            .whereJoined(.posts, .likes, .gte, 10).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{1}, rows);
    }
    {
        const rows = try users.join(.posts).whereJoined(.posts, .published, .eq, false)
            .whereJoined(.posts, .likes, .gte, 100).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{}, rows);
    }
    // Strings, `in` and the relation's own filters, groups and paging.
    {
        const rows = try users.whereAny(.{ .{ .role, .eq, .admin }, .{ .age, .is_null, {} } })
            .join(.posts).whereJoined(.posts, .title, .ilike, "%RAFT").toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{3}, rows);
    }
    {
        const rows = try users.join(.posts).whereJoined(.posts, .id, .in, .{ 10, 12, 14 })
            .order(.name, .desc).offset(1).limit(1).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{1}, rows);
    }
    try testing.expectEqual(1, try users.join(.posts).order(.id, .asc).offset(2).count());

    // A projection: one row per user, even when the selected values repeat.
    {
        const rel = users.select(.{.role}).join(.posts).order(.age, .desc);
        const rows = try rel.toSlice(a);
        defer rel.free(a, rows);
        try testing.expectEqual(3, rows.len);
        // Nulls first on desc: Wanjiru, then Achieng (31), then Otieno (24).
        try testing.expectEqual(Role.member, rows[0].role);
        try testing.expectEqual(Role.admin, rows[1].role);
        try testing.expectEqual(Role.member, rows[2].role);
    }

    // belongsTo: the posts of admins; the orphan has no author to join.
    {
        const rows = try posts.join(.author).whereJoined(.author, .role, .eq, .admin).order(.id, .asc).toSlice(a);
        defer posts.free(a, rows);
        try expectIds(&.{ 10, 11, 14 }, rows);
    }
    try testing.expectEqual(5, try posts.join(.author).count());

    // join, then combine: authors with a published post, with all their posts.
    {
        const Author = struct { id: u32, name: []const u8, posts: []const Post };
        var result = try users.join(.posts).whereJoined(.posts, .published, .eq, true).order(.id, .asc)
            .combine(.posts, posts.order(.id, .asc)).mapTo(Author, a);
        defer result.deinit();
        try testing.expectEqual(2, result.items.len);
        try testing.expectEqual(3, result.items[0].posts.len);
        try testing.expectEqual(1, result.items[1].posts.len);
    }

    // Runtime lists on the joined table, borrowed like whereIn's.
    {
        const ids = [_]u32{ 13, 14, 15 };
        const rows = try users.join(.posts).whereJoinedIn(.posts, .id, ids[0..]).order(.id, .asc).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{ 1, 3 }, rows);
    }
    {
        // A null user_id is in no list and outside none: the orphan never joins anyway.
        const ones = [_]u32{1};
        const rows = try users.join(.posts).whereJoinedNotIn(.posts, .user_id, &ones).order(.id, .asc).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{ 2, 3 }, rows);
    }
    {
        // Empty runtime lists on a nullable joined column.
        const none: []const u32 = &.{};
        try testing.expectEqual(0, try users.join(.posts).whereJoinedIn(.posts, .user_id, none).count());
        try testing.expectEqual(3, try users.join(.posts).whereJoinedNotIn(.posts, .user_id, none).count());
    }

    // Groups on the joined rows: a draft or 10+ likes...
    {
        const rows = try users.join(.posts)
            .whereJoinedAny(.posts, .{ .{ .published, .eq, false }, .{ .likes, .gte, 10 } })
            .order(.id, .asc).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{ 1, 3 }, rows);
    }
    // ...AND-ed with a top-level joined filter, all for one post (#11 or #14).
    {
        const rows = try users.join(.posts)
            .whereJoinedAny(.posts, .{ .{ .published, .eq, false }, .{ .title, .ilike, "%sql" } })
            .whereJoined(.posts, .likes, .gte, 10)
            .toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{1}, rows);
    }
    {
        const rows = try users.join(.posts).whereJoinedNot(.posts, .{ .published, .eq, true }).order(.id, .asc).toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{ 1, 3 }, rows);
    }
    {
        // Published with fewer than 10 likes (#10, #12), and the user's own filter.
        const rows = try users.where(.role, .eq, .member).join(.posts)
            .whereJoinedNot(.posts, zom.any(.{ .{ .published, .eq, false }, .{ .likes, .gte, 10 } }))
            .toSlice(a);
        defer users.free(a, rows);
        try expectIds(&.{2}, rows);
    }
    {
        const rows = try posts.join(.author)
            .whereJoinedAny(.author, .{ .{ .role, .eq, .admin }, .{ .age, .is_null, {} } })
            .order(.id, .asc).toSlice(a);
        defer posts.free(a, rows);
        try expectIds(&.{ 10, 11, 13, 14 }, rows);
    }
    {
        // NOT keeps unknown unknown: Wanjiru's null age is not "not over 30".
        const rows = try posts.join(.author).whereJoinedNot(.author, .{ .age, .gt, 30 }).toSlice(a);
        defer posts.free(a, rows);
        try expectIds(&.{12}, rows);
    }

    // The same joined writes run against memory and PostgreSQL.
    try testing.expectEqual(2, try users.join(.posts).whereJoined(.posts, .published, .eq, false).update().set(.age, 1).commit());
    try testing.expectEqual(0, try posts.join(.author).whereJoined(.author, .age, .eq, 1).where(.id, .eq, 15).delete());
    try testing.expectEqual(2, try posts.join(.author).whereJoined(.author, .age, .eq, 1).where(.published, .eq, false).delete());
    try testing.expectEqual(4, try posts.count());
}

fn expectIds(expected: []const u32, rows: anytype) !void {
    var ids: [8]u32 = undefined;
    try testing.expectEqual(expected.len, rows.len);
    for (rows, 0..) |r, i| ids[i] = r.id;
    try testing.expectEqualSlices(u32, expected, ids[0..rows.len]);
}

test "join: memory" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    try scenario(zom.memory.Gateway, &gw);
}

test "join: postgres" {
    const u = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(u);
    var gw = try zom_pg.Gateway.init(testing.allocator, .{ .io = testing.io, .url = u, .pool_size = 2 });
    defer gw.deinit();
    try gw.exec("DROP TABLE IF EXISTS pj_posts");
    try gw.exec("DROP TABLE IF EXISTS pj_users");
    defer {
        gw.exec("DROP TABLE IF EXISTS pj_posts") catch {};
        gw.exec("DROP TABLE IF EXISTS pj_users") catch {};
    }
    try gw.exec(create_users);
    try gw.exec(create_posts);
    try scenario(zom_pg.Gateway, &gw);
}
