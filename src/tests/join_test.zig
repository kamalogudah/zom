const std = @import("std");
const testing = std.testing;
const zom = @import("../root.zig");

const Role = enum { admin, member };

const User = struct {
    id: u32,
    name: []const u8,
    age: u8,
    role: Role = .member,
};

const Post = struct {
    id: u32,
    /// Optional, so a post can belong to nobody.
    user_id: ?u32,
    title: []const u8,
    published: bool,
    likes: u32 = 0,
};

const Comment = struct {
    id: u32,
    user_id: ?u32,
    body: []const u8,
    flagged: bool = false,
};

const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
        pub const comments = zom.hasMany(CommentSchema, .user_id);
    },
});
const CommentSchema = zom.Schema(Comment, "comments", .id, .{});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
    },
});

const Users = zom.Relation(UserSchema, zom.memory.Gateway);
const Posts = zom.Relation(PostSchema, zom.memory.Gateway);
const Comments = zom.Relation(CommentSchema, zom.memory.Gateway);

/// Achieng has two posts, one published; Otieno one published; Wanjiru one
/// draft; Kamau none. Post 15 belongs to nobody. Otieno comments twice,
/// Wanjiru once (flagged), Kamau once; Achieng never.
fn seed(users: Users, posts: Posts, comments: Comments) !void {
    _ = try users.createMany(&.{
        .{ .id = 1, .name = "Achieng", .age = 31, .role = .admin },
        .{ .id = 2, .name = "Otieno", .age = 24 },
        .{ .id = 3, .name = "Wanjiru", .age = 42 },
        .{ .id = 4, .name = "Kamau", .age = 19 },
    }).commit();
    _ = try posts.createMany(&.{
        .{ .id = 10, .user_id = 1, .title = "Relations are values", .published = true, .likes = 5 },
        .{ .id = 11, .user_id = 1, .title = "Mappers, not models", .published = false, .likes = 50 },
        .{ .id = 12, .user_id = 2, .title = "Comptime schemas", .published = true, .likes = 7 },
        .{ .id = 13, .user_id = 3, .title = "Draft", .published = false },
        .{ .id = 15, .user_id = null, .title = "Orphan", .published = true, .likes = 99 },
    }).commit();
    _ = try comments.createMany(&.{
        .{ .id = 20, .user_id = 2, .body = "Nice" },
        .{ .id = 21, .user_id = 3, .body = "Spam", .flagged = true },
        .{ .id = 22, .user_id = 2, .body = "Again" },
        .{ .id = 23, .user_id = 4, .body = "First!" },
    }).commit();
}

const Fixture = struct {
    gw: zom.memory.Gateway,
    users: Users = undefined,
    posts: Posts = undefined,
    comments: Comments = undefined,

    fn init(self: *Fixture) !void {
        self.gw = .init(testing.allocator, .{});
        errdefer self.gw.deinit();
        self.users = try .init(&self.gw);
        self.posts = try .init(&self.gw);
        self.comments = try .init(&self.gw);
        try seed(self.users, self.posts, self.comments);
    }

    fn deinit(self: *Fixture) void {
        self.gw.deinit();
    }
};

fn expectIds(expected: []const u32, rows: anytype) !void {
    var ids: [16]u32 = undefined;
    for (rows, 0..) |r, i| ids[i] = r.id;
    try testing.expectEqualSlices(u32, expected, ids[0..rows.len]);
}

test "join(.posts): the users with at least one post, each once" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();

    const rows = try f.users.join(.posts).order(.id, .asc).toSlice(testing.allocator);
    defer f.users.free(testing.allocator, rows);
    // Achieng has two posts and still comes back once; Kamau has none.
    try expectIds(&.{ 1, 2, 3 }, rows);
    try testing.expectEqual(3, try f.users.join(.posts).count());
}

test "whereJoined filters the joined rows; several must hold for the same one" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    {
        const rows = try f.users.join(.posts).whereJoined(.posts, .published, .eq, true).order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 1, 2 }, rows);
    }
    {
        // Achieng has a published post and a post with 50 likes, but not
        // one post that is both.
        const rows = try f.users.join(.posts)
            .whereJoined(.posts, .published, .eq, true)
            .whereJoined(.posts, .likes, .gte, 10)
            .toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{}, rows);
    }
    {
        const rows = try f.users.join(.posts).whereJoined(.posts, .title, .like, "%schemas").toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{2}, rows);
    }
    {
        const rows = try f.users.join(.posts).whereJoined(.posts, .id, .in, .{ 11, 13 }).order(.id, .desc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 3, 1 }, rows);
    }
}

test "join keeps the relation's own filters, order, paging and count" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    const joined = f.users.where(.age, .lt, 40).join(.posts);
    {
        const rows = try joined.order(.age, .desc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 1, 2 }, rows);
    }
    {
        const rows = try f.users.join(.posts).order(.name, .asc).offset(1).limit(1).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{2}, rows);
    }
    try testing.expectEqual(2, try joined.count());
    try testing.expectEqual(1, try f.users.join(.posts).limit(1).count());

    // `where` after `join` filters the same way as before it.
    const after = try f.users.join(.posts).where(.role, .eq, .admin).toSlice(a);
    defer f.users.free(a, after);
    try expectIds(&.{1}, after);

    const one = (try f.users.join(.posts).whereJoined(.posts, .likes, .eq, 7).one(a)).?;
    try testing.expectEqualStrings("Otieno", one.name);
}

test "join after select reads the narrow struct, one per parent" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    const rel = f.users.select(.{.role}).join(.posts).order(.id, .asc);
    const rows = try rel.toSlice(a);
    defer rel.free(a, rows);
    // Not deduplicated by value: two members, two rows.
    try testing.expectEqual(3, rows.len);
    try testing.expectEqual(Role.admin, rows[0].role);
    try testing.expectEqual(Role.member, rows[1].role);
    try testing.expectEqual(Role.member, rows[2].role);
}

test "belongsTo: posts.join(.author) keeps the posts whose author matches" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    {
        // The orphan (null user_id) has no author to join.
        const rows = try f.posts.join(.author).order(.id, .asc).toSlice(a);
        defer f.posts.free(a, rows);
        try expectIds(&.{ 10, 11, 12, 13 }, rows);
    }
    {
        const rows = try f.posts.join(.author).whereJoined(.author, .role, .eq, .admin)
            .where(.published, .eq, true).toSlice(a);
        defer f.posts.free(a, rows);
        try expectIds(&.{10}, rows);
    }
}

test "joining the same association again changes nothing" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    const rel = f.users.join(.posts).whereJoined(.posts, .published, .eq, false).join(.posts);
    try testing.expectEqual(1, rel.query.joinSlice()[0].filter_count);
    const rows = try rel.order(.id, .asc).toSlice(a);
    defer f.users.free(a, rows);
    try expectIds(&.{ 1, 3 }, rows);
}

test "joined update and delete use the matching semi-join rows" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();

    const joined = f.users.join(.posts).whereJoined(.posts, .published, .eq, false);
    try testing.expectEqual(2, try joined.update().set(.age, 1).commit());
    try testing.expectEqual(0, try f.users.join(.posts).whereJoined(.posts, .published, .eq, false).where(.age, .gt, 1).delete());
    try testing.expectEqual(1, try f.users.join(.posts).whereJoined(.posts, .published, .eq, true).where(.id, .eq, 2).delete());
    try testing.expectEqual(2, try joined.delete());
    try testing.expectEqual(1, try f.users.count());
    try testing.expectEqual(4, (try f.users.one(testing.allocator)).?.id);
}

test "join and combine together: authors with a published post, with all their posts" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();

    const Author = struct { id: u32, name: []const u8, posts: []const Post };
    var result = try f.users.join(.posts).whereJoined(.posts, .published, .eq, true)
        .order(.id, .asc)
        .combine(.posts, f.posts.order(.id, .asc))
        .mapTo(Author, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(2, result.items.len);
    try testing.expectEqual(2, result.items[0].posts.len);
    try testing.expectEqual(11, result.items[0].posts[1].id);
    try testing.expectEqual(1, result.items[1].posts.len);
}

/// Memory without `like`, so a `.fallback` relation splits its query: the
/// join must stay with what goes to the dataset.
const NoLikeGateway = struct {
    pub const adapter_name = "nolike";
    pub const Config = struct {};

    inner: zom.memory.Gateway,

    pub fn init(allocator: std.mem.Allocator, _: Config) NoLikeGateway {
        return .{ .inner = .init(allocator, .{}) };
    }
    pub fn deinit(self: *NoLikeGateway) void {
        self.inner.deinit();
    }

    pub fn Dataset(comptime S: type) type {
        return struct {
            const Q = zom.Query(S.Tuple);
            pub const supports: zom.Supports = blk: {
                var s: zom.Supports = .all;
                s.like = false;
                s.projection = false;
                break :blk s;
            };

            store: *zom.memory.Store(S) = undefined,
            last: Q = .{},

            pub fn read(self: *@This(), query: Q, allocator: std.mem.Allocator) ![]S.Tuple {
                self.last = query;
                return self.store.read(query, allocator);
            }
            pub fn count(self: *@This(), query: Q) !usize {
                return self.store.count(query);
            }
            pub fn insertMany(self: *@This(), rows: []const S.Tuple) !usize {
                return self.store.insertMany(rows);
            }
        };
    }

    pub fn dataset(self: *NoLikeGateway, comptime S: type) !*Dataset(S) {
        const static = struct {
            var instance: Dataset(S) = .{};
        };
        static.instance.store = try self.inner.dataset(S);
        return &static.instance;
    }
};

test "fallback: the join goes to the dataset, the unsupported filter runs in memory" {
    var gw: NoLikeGateway = .init(testing.allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(UserSchema, NoLikeGateway).init(&gw);
    const posts = try zom.Relation(PostSchema, NoLikeGateway).init(&gw);
    _ = try users.createMany(&.{
        .{ .id = 1, .name = "Achieng", .age = 31 },
        .{ .id = 2, .name = "Akinyi", .age = 24 },
        .{ .id = 3, .name = "Otieno", .age = 42 },
    }).commit();
    _ = try posts.createMany(&.{
        .{ .id = 10, .user_id = 1, .title = "a", .published = true },
        .{ .id = 11, .user_id = 3, .title = "b", .published = true },
    }).commit();

    const rel = users.allowFallback().join(.posts).where(.name, .like, "A%");
    const rows = try rel.toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);
    try expectIds(&.{1}, rows);
    const pushed = gw.dataset(UserSchema) catch unreachable;
    try testing.expect(pushed.last.join_count == 1);
    try testing.expectEqual(0, pushed.last.filter_count);
}

test "a store no memory gateway handed out can't join" {
    var store = zom.memory.Store(UserSchema).init(testing.allocator);
    defer store.deinit();
    _ = try store.insert(.{ .id = 1, .name = "a", .age = 1 });
    var query: zom.Query(User) = .{};
    query.addJoin(.{ .assoc = "posts", .table = "posts", .source_key = "id", .target_key = "user_id" });
    try testing.expectError(error.JoinUnavailable, store.read(query, testing.allocator));
}

test "Join.targetQuery gives back typed filters over the joined tuple" {
    var j: zom.Join = .{ .assoc = "posts", .table = "posts", .source_key = "id", .target_key = "user_id" };
    j = j.where(Post, .published, .eq, true).where(Post, .user_id, .eq, null);
    try testing.expectEqualStrings("published", j.filterSlice()[0].column);
    try testing.expect(!j.filterSlice()[0].nullable);
    try testing.expect(j.filterSlice()[1].nullable);
    // `eq null` is normalised on the way in, as in a query.
    try testing.expectEqual(zom.Op.is_null, j.filterSlice()[1].op);

    const tq = j.targetQuery(Post);
    try testing.expectEqual(2, tq.filter_count);
    try testing.expect(tq.matches(.{ .id = 1, .user_id = null, .title = "", .published = true }));
    try testing.expect(!tq.matches(.{ .id = 1, .user_id = 3, .title = "", .published = true }));
}

test "whereJoinedIn / whereJoinedNotIn take a runtime slice of joined values" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    var ids = [_]u32{ 11, 13 };
    {
        const rows = try f.users.join(.posts).whereJoinedIn(.posts, .id, ids[0..]).order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 1, 3 }, rows);
    }
    {
        // A pointer to an array works too. Every post but 10, 11 and 12.
        const skip = [_]u32{ 10, 11, 12 };
        const rows = try f.users.join(.posts).whereJoinedNotIn(.posts, .id, &skip).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{3}, rows);
    }
    {
        // An empty list matches no joined row.
        const none: []const u32 = &.{};
        const rows = try f.users.join(.posts).whereJoinedIn(.posts, .id, none).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{}, rows);
    }
    // The slice is borrowed: changing it changes what the relation reads.
    const rel = f.users.join(.posts).whereJoinedIn(.posts, .id, ids[0..]);
    try testing.expectEqual(2, try rel.count());
    ids = .{ 12, 12 };
    try testing.expectEqual(1, try rel.count());
}

test "whereJoinedAny: one joined row satisfies some condition" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    {
        // The issue's example: a post that is published OR has 10+ likes.
        const rows = try f.users.join(.posts)
            .whereJoinedAny(.posts, .{ .{ .published, .eq, true }, .{ .likes, .gte, 10 } })
            .order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 1, 2 }, rows);
    }
    {
        // AND-ed with a top-level joined filter, for the same row: a draft
        // with 10+ likes or titled "Draft". Achieng (#11) and Wanjiru (#13).
        const rows = try f.users.join(.posts)
            .whereJoined(.posts, .published, .eq, false)
            .whereJoinedAny(.posts, .{ .{ .likes, .gte, 10 }, .{ .title, .eq, "Draft" } })
            .order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 1, 3 }, rows);
    }
    {
        // Nested groups and a runtime slice inside one.
        const few = [_]u32{13};
        const rows = try f.users.join(.posts)
            .whereJoinedAny(.posts, .{
                zom.all(.{ .{ .published, .eq, true }, .{ .likes, .lt, 6 } }),
                .{ .id, .in, few[0..] },
            })
            .order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 1, 3 }, rows);
    }
}

test "whereJoinedNot: a joined row for which the condition is false" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    {
        // A post that is not published: not the users without a published post.
        const rows = try f.users.join(.posts).whereJoinedNot(.posts, .{ .published, .eq, true }).order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 1, 3 }, rows);
    }
    {
        const rows = try f.users.join(.posts)
            .whereJoinedNot(.posts, zom.any(.{ .{ .published, .eq, false }, .{ .likes, .gte, 6 } }))
            .toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{1}, rows);
    }
    // belongsTo: posts whose author is not an admin. The orphan has no author.
    {
        const rows = try f.posts.join(.author).whereJoinedNot(.author, .{ .role, .eq, .admin }).order(.id, .asc).toSlice(a);
        defer f.posts.free(a, rows);
        try expectIds(&.{ 12, 13 }, rows);
    }
}

test "Join holds a group as a flat tree, and targetQuery rebuilds it" {
    var j: zom.Join = .{ .assoc = "posts", .table = "posts", .source_key = "id", .target_key = "user_id" };
    j = j.where(Post, .published, .eq, true)
        .whereAny(Post, .{ .{ .likes, .gte, 10 }, zom.not(.{ .title, .eq, "x" }) })
        .whereNot(Post, .{ .user_id, .is_null, {} });
    try testing.expect(!j.isConjunction());
    try testing.expectEqual(4, j.filter_count);
    // Three top-level nodes; the any has two children, one a not.
    try testing.expectEqual(7, j.node_count);
    try testing.expectEqual(3, j.top.count());

    // The tree is copied by value with the join.
    const copy = j;
    const tq = copy.targetQuery(Post);
    try testing.expectEqual(4, tq.filter_count);
    try testing.expectEqual(7, tq.node_count);
    const row: Post = .{ .id = 1, .user_id = 2, .title = "y", .published = true };
    try testing.expect(tq.matches(row));
    try testing.expect(!tq.matches(.{ .id = 1, .user_id = null, .title = "y", .published = true }));
    try testing.expect(!tq.matches(.{ .id = 1, .user_id = 2, .title = "x", .published = true, .likes = 3 }));
    try testing.expect(tq.matches(.{ .id = 1, .user_id = 2, .title = "x", .published = true, .likes = 30 }));
}

test "two joins: the users with a post and with a comment, each joined row on its own" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();
    const a = testing.allocator;

    {
        const rows = try f.users.join(.posts).join(.comments).order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 2, 3 }, rows);
    }
    {
        // The order joined doesn't matter.
        const rows = try f.users.join(.comments).join(.posts).order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{ 2, 3 }, rows);
    }
    try testing.expectEqual(2, try f.users.join(.posts).join(.comments).count());
    {
        // Each whereJoined narrows its own join only.
        const rows = try f.users.join(.posts).join(.comments)
            .whereJoined(.posts, .published, .eq, true)
            .order(.id, .asc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{2}, rows);
    }
    {
        const rows = try f.users.join(.posts).whereJoined(.posts, .published, .eq, false)
            .join(.comments).whereJoined(.comments, .flagged, .eq, true)
            .toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{3}, rows);
    }
    try testing.expectEqual(0, try f.users.join(.posts).whereJoined(.posts, .published, .eq, true)
        .join(.comments).whereJoined(.comments, .flagged, .eq, true).count());
    {
        const rows = try f.users.join(.posts).join(.comments).whereJoinedNot(.comments, .{ .flagged, .eq, true })
            .where(.age, .gt, 20).order(.id, .desc).toSlice(a);
        defer f.users.free(a, rows);
        try expectIds(&.{2}, rows);
    }
}

test "joining an association again is a no-op, filters kept, other joins untouched" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();

    const rel = f.users.join(.posts).whereJoined(.posts, .published, .eq, false)
        .join(.comments).join(.posts).whereJoined(.comments, .flagged, .eq, true);
    try testing.expectEqual(2, rel.query.join_count);
    const joins = rel.query.joinSlice();
    try testing.expectEqualStrings("posts", joins[0].assoc);
    try testing.expectEqual(1, joins[0].filter_count);
    try testing.expectEqualStrings("comments", joins[1].assoc);
    try testing.expectEqual(1, joins[1].filter_count);
    try testing.expectEqual(1, try rel.count());
}

test "two joins on update and delete: every join must match" {
    var f: Fixture = .{ .gw = undefined };
    try f.init();
    defer f.deinit();

    try testing.expectEqual(2, try f.users.join(.posts).join(.comments).update().set(.age, 1).commit());
    try testing.expectEqual(2, try f.users.where(.age, .eq, 1).count());
    try testing.expectEqual(1, try f.users.join(.comments).whereJoined(.comments, .flagged, .eq, true).join(.posts).delete());
    try testing.expectEqual(1, try f.users.join(.posts).join(.comments).delete());
    const rows = try f.users.order(.id, .asc).toSlice(testing.allocator);
    defer f.users.free(testing.allocator, rows);
    try expectIds(&.{ 1, 4 }, rows);
}

const Person = struct { id: u32, manager_id: ?u32, name: []const u8 };
const Note = struct { id: u32, person_id: u32 };
const PersonSchema = zom.Schema(Person, "people", .id, .{
    .associations = struct {
        pub const manager = zom.belongsTo(PersonSchema, .manager_id);
        pub const notes = zom.hasMany(NoteSchema, .person_id);
    },
});
const NoteSchema = zom.Schema(Note, "notes", .id, .{});

test "a self-join and a second join snapshot membership before a delete" {
    var gw: zom.memory.Gateway = .init(testing.allocator, .{});
    defer gw.deinit();
    const people = try zom.Relation(PersonSchema, zom.memory.Gateway).init(&gw);
    const notes = try zom.Relation(NoteSchema, zom.memory.Gateway).init(&gw);
    // 2 reports to 1, 3 to 2: deleting 2 first must not drop 3 from the
    // snapshot.
    _ = try people.createMany(&.{
        .{ .id = 1, .manager_id = null, .name = "a" },
        .{ .id = 2, .manager_id = 1, .name = "b" },
        .{ .id = 3, .manager_id = 2, .name = "c" },
    }).commit();
    _ = try notes.createMany(&.{
        .{ .id = 10, .person_id = 2 },
        .{ .id = 11, .person_id = 3 },
    }).commit();
    try testing.expectEqual(2, try people.join(.manager).join(.notes).delete());
    try testing.expectEqual(1, try people.count());
}
