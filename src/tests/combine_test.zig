const std = @import("std");
const testing = std.testing;
const zom = @import("../root.zig");
const fixtures = @import("fixtures.zig");

const UserTuple = fixtures.UserTuple;
const PostTuple = fixtures.PostTuple;
const Post = fixtures.Post;
const Author = fixtures.Author;
const AuthorMapper = fixtures.AuthorMapper;

const UserSchema = zom.Schema(UserTuple, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(PostTuple, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
        pub const comments = zom.hasMany(CommentSchema, .post_id);
    },
});
const CommentTuple = struct { id: u32, post_id: u32, body: []const u8 };
const CommentSchema = zom.Schema(CommentTuple, "comments", .id, .{
    .associations = struct {
        pub const post = zom.belongsTo(PostSchema, .post_id);
    },
});

/// A memory gateway whose datasets count their reads, so a test can assert
/// how many queries a combine made.
const CountingGateway = struct {
    pub const adapter_name = "counting";
    pub const Config = struct {};

    inner: zom.memory.Gateway,

    pub fn init(allocator: std.mem.Allocator, _: Config) CountingGateway {
        return .{ .inner = .init(allocator, .{}) };
    }

    pub fn deinit(self: *CountingGateway) void {
        self.inner.deinit();
    }

    pub fn Dataset(comptime S: type) type {
        return struct {
            const Self = @This();
            const T = S.Tuple;
            const Q = zom.Query(T);
            pub const supports: zom.Supports = blk: {
                var all: zom.Supports = .all;
                all.projection = false;
                break :blk all;
            };

            store: *zom.memory.Store(S) = undefined,
            reads: usize = 0,

            pub fn read(self: *Self, query: Q, allocator: std.mem.Allocator) ![]T {
                self.reads += 1;
                return self.store.read(query, allocator);
            }
            pub fn count(self: *Self, query: Q) !usize {
                return self.store.count(query);
            }
            pub fn insert(self: *Self, row: T) !T {
                return self.store.insert(row);
            }
        };
    }

    pub fn dataset(self: *CountingGateway, comptime S: type) !*Dataset(S) {
        const static = struct {
            var instance: Dataset(S) = .{};
        };
        static.instance = .{ .store = try self.inner.dataset(S) };
        return &static.instance;
    }
};

fn Fixture(comptime G: type) type {
    return struct {
        gw: G,
        users: zom.Relation(UserSchema, G),
        posts: zom.Relation(PostSchema, G),

        fn init(self: *@This()) !void {
            self.gw = G.init(testing.allocator, .{});
            errdefer self.gw.deinit();
            self.users = try .init(&self.gw);
            self.posts = try .init(&self.gw);
            // The same rows as fixtures.seed, plus a post by a user who
            // doesn't exist.
            const users = self.users;
            const posts = self.posts;
            _ = try users.create(.{ .id = 1, .name = "Achieng", .email = "achieng@example.com", .age = 31, .role = .admin }).commit();
            _ = try users.create(.{ .id = 2, .name = "Otieno", .email = "otieno@example.com", .age = 24 }).commit();
            _ = try users.create(.{ .id = 3, .name = "Wanjiru", .email = "wanjiru@example.com", .age = 42, .deleted_at = 1_700_000_000 }).commit();
            _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values", .published = true }).commit();
            _ = try posts.create(.{ .id = 11, .user_id = 1, .title = "Mappers, not models", .published = false }).commit();
            _ = try posts.create(.{ .id = 12, .user_id = 2, .title = "Comptime schemas", .published = true }).commit();
            _ = try posts.create(.{ .id = 13, .user_id = 3, .title = "Soft deletes", .published = true }).commit();
            _ = try posts.create(.{ .id = 14, .user_id = 9, .title = "Orphan", .published = true }).commit();
        }

        fn deinit(self: *@This()) void {
            self.gw.deinit();
        }
    };
}

test "combine(.posts) gives what combineMany gave, with one child query" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;
    post_reads.* = 0;

    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.where(.published, .eq, true).order(.id, .asc))
        .mapWith(AuthorMapper, testing.allocator);
    defer result.deinit();
    const authors = result.items;

    try testing.expectEqual(1, post_reads.*);
    try testing.expectEqual(2, authors.len);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
    try testing.expectEqual(1, authors[0].posts.len);
    try testing.expectEqualStrings("Relations are values", authors[0].posts[0].title);
    try testing.expectEqual(1, authors[1].posts.len);
    try testing.expectEqualStrings("Comptime schemas", authors[1].posts[0].title);
}

const Writer = struct { id: u32, name: []const u8, posts: []const Post };

test "combine: a parent with no children gets an empty slice; orphans are dropped" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    // Only user 3's post (13) and the orphan (14) match; user 3 is filtered out.
    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.where(.id, .gte, 13))
        .mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(2, result.items.len);
    for (result.items) |w| try testing.expectEqual(0, w.posts.len);
}

test "combine: children keep the target relation's order within each parent" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    var result = try f.users.byPk(1).combine(.posts, f.posts.order(.id, .desc)).mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(1, result.items.len);
    const posts = result.items[0].posts;
    try testing.expectEqual(2, posts.len);
    try testing.expectEqual(11, posts[0].id);
    try testing.expectEqual(10, posts[1].id);
}

test "combine: the parent's limit applies to parents, and no keys means no child query" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;

    post_reads.* = 0;
    var one = try f.users.order(.id, .desc).limit(1).combine(.posts, f.posts).mapTo(Writer, testing.allocator);
    defer one.deinit();
    try testing.expectEqual(1, one.items.len);
    try testing.expectEqualStrings("Wanjiru", one.items[0].name);
    try testing.expectEqual(1, one.items[0].posts.len);
    try testing.expectEqual(1, post_reads.*);

    post_reads.* = 0;
    var none = try f.users.where(.id, .gt, 100).combine(.posts, f.posts).mapTo(Writer, testing.allocator);
    defer none.deinit();
    try testing.expectEqual(0, none.items.len);
    try testing.expectEqual(0, post_reads.*);
}

const PostWithAuthor = struct {
    id: u32,
    title: []const u8,
    author: ?struct { id: u32, name: []const u8 },
};

test "combine(.author): belongs-to gives each child its parent, or null" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const user_reads = &(try f.gw.dataset(UserSchema)).reads;
    user_reads.* = 0;

    var result = try f.posts.order(.id, .asc)
        .combine(.author, f.users.where(.deleted_at, .eq, null))
        .mapTo(PostWithAuthor, testing.allocator);
    defer result.deinit();
    const posts = result.items;

    try testing.expectEqual(1, user_reads.*);
    try testing.expectEqual(5, posts.len);
    try testing.expectEqualStrings("Achieng", posts[0].author.?.name);
    try testing.expectEqualStrings("Achieng", posts[1].author.?.name);
    try testing.expectEqualStrings("Otieno", posts[2].author.?.name);
    // User 3 is filtered out of the target relation, and user 9 doesn't exist.
    try testing.expect(posts[3].author == null);
    try testing.expect(posts[4].author == null);
}

test "combine: more keys than max_in are read in ceil(keys / max_in) queries" {
    var gw: CountingGateway = .init(testing.allocator, .{});
    defer gw.deinit();
    const users: zom.Relation(UserSchema, CountingGateway) = try .init(&gw);
    const posts: zom.Relation(PostSchema, CountingGateway) = try .init(&gw);

    const max_in = zom.Query(PostTuple).max_in;
    const n_users = 2 * max_in + 5;
    for (0..n_users) |i| {
        const id: u32 = @intCast(i + 1);
        _ = try users.create(.{ .id = id, .name = "u", .email = "u@example.com", .age = 20 }).commit();
        // Every other user has two posts.
        if (i % 2 == 0) {
            _ = try posts.create(.{ .id = 2 * id, .user_id = id, .title = "a", .published = true }).commit();
            _ = try posts.create(.{ .id = 2 * id + 1, .user_id = id, .title = "b", .published = true }).commit();
        }
    }
    const post_reads = &(try gw.dataset(PostSchema)).reads;
    post_reads.* = 0;

    var result = try users.order(.id, .asc).combine(.posts, posts).mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(std.math.divCeil(usize, n_users, max_in) catch unreachable, post_reads.*);
    try testing.expectEqual(n_users, result.items.len);
    for (result.items, 0..) |w, i| {
        try testing.expectEqual(@as(u32, @intCast(i + 1)), w.id);
        try testing.expectEqual(@as(usize, if (i % 2 == 0) 2 else 0), w.posts.len);
        for (w.posts) |p| try testing.expectEqual(w.id, p.user_id);
    }
}

fn expectPostIds(want: []const u32, got: []const Post) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqual(w, g.id);
}

test "combine: the target's limit and offset page each parent's rows, in one query" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;
    const users = f.users.order(.id, .asc);
    const latest = f.posts.order(.id, .desc);

    // The latest post of each user: a limit on the query would give one post in all.
    post_reads.* = 0;
    var one = try users.combine(.posts, latest.limit(1)).mapTo(Writer, testing.allocator);
    defer one.deinit();
    try testing.expectEqual(1, post_reads.*);
    try testing.expectEqual(3, one.items.len);
    try expectPostIds(&.{11}, one.items[0].posts);
    try expectPostIds(&.{12}, one.items[1].posts);
    try expectPostIds(&.{13}, one.items[2].posts);

    // offset skips within each parent; past the end gives an empty slice.
    var skipped = try users.combine(.posts, latest.offset(1)).mapTo(Writer, testing.allocator);
    defer skipped.deinit();
    try expectPostIds(&.{10}, skipped.items[0].posts);
    try expectPostIds(&.{}, skipped.items[1].posts);
    try expectPostIds(&.{}, skipped.items[2].posts);

    // Both, with the target's filters applied before the page.
    var paged = try users.combine(.posts, f.posts.where(.id, .lt, 13).order(.id, .asc).offset(1).limit(5)).mapTo(Writer, testing.allocator);
    defer paged.deinit();
    try expectPostIds(&.{11}, paged.items[0].posts);
    try expectPostIds(&.{}, paged.items[1].posts);

    // limit(0) gives every parent an empty slice.
    var zero = try users.combine(.posts, f.posts.limit(0)).mapTo(Writer, testing.allocator);
    defer zero.deinit();
    for (zero.items) |w| try expectPostIds(&.{}, w.posts);
}

test "combine: a paged belongs-to target gives the first parent of each page, or null" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    var kept = try f.posts.order(.id, .asc).combine(.author, f.users.limit(1)).mapTo(PostWithAuthor, testing.allocator);
    defer kept.deinit();
    try testing.expectEqualStrings("Achieng", kept.items[0].author.?.name);
    try testing.expectEqualStrings("Otieno", kept.items[2].author.?.name);
    try testing.expectEqualStrings("Wanjiru", kept.items[3].author.?.name);
    try testing.expect(kept.items[4].author == null);

    var skipped = try f.posts.order(.id, .asc).combine(.author, f.users.offset(1)).mapTo(PostWithAuthor, testing.allocator);
    defer skipped.deinit();
    for (skipped.items) |p| try testing.expect(p.author == null);
}

test "combine: per-parent paging holds across ceil(keys / max_in) batched queries" {
    var gw: CountingGateway = .init(testing.allocator, .{});
    defer gw.deinit();
    const users: zom.Relation(UserSchema, CountingGateway) = try .init(&gw);
    const posts: zom.Relation(PostSchema, CountingGateway) = try .init(&gw);

    const max_in = zom.Query(PostTuple).max_in;
    const n_users = 2 * max_in + 5;
    for (0..n_users) |i| {
        const id: u32 = @intCast(i + 1);
        _ = try users.create(.{ .id = id, .name = "u", .email = "u@example.com", .age = 20 }).commit();
        for (0..3) |j| {
            const post_id: u32 = @intCast(3 * id + j);
            _ = try posts.create(.{ .id = post_id, .user_id = id, .title = "p", .published = true }).commit();
        }
    }
    const post_reads = &(try gw.dataset(PostSchema)).reads;
    post_reads.* = 0;

    var result = try users.order(.id, .asc).combine(.posts, posts.order(.id, .desc).offset(1).limit(1)).mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(std.math.divCeil(usize, n_users, max_in) catch unreachable, post_reads.*);
    try testing.expectEqual(n_users, result.items.len);
    for (result.items) |w| try expectPostIds(&.{3 * w.id + 1}, w.posts);
}

test "combine: a paged target frees cleanly when allocation fails partway" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();
    const run = struct {
        fn run(allocator: std.mem.Allocator, users: zom.Relation(UserSchema, zom.memory.Gateway), posts: zom.Relation(PostSchema, zom.memory.Gateway)) !void {
            var result = try users.combine(.posts, posts.order(.id, .desc).offset(1).limit(1)).mapTo(Writer, allocator);
            result.deinit();
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{ f.users, f.posts });
}

test "combine: the result frees cleanly when allocation fails partway" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();
    const run = struct {
        fn run(
            allocator: std.mem.Allocator,
            users: zom.Relation(UserSchema, zom.memory.Gateway),
            posts: zom.Relation(PostSchema, zom.memory.Gateway),
        ) !void {
            var result = try users.combine(.posts, posts).mapWith(AuthorMapper, allocator);
            result.deinit();
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{ f.users, f.posts });
}

// -- nested combines -----------------------------------------------------------

const Comment = struct { id: u32, body: []const u8 };
const PostWithComments = struct { id: u32, title: []const u8, comments: []const Comment };
const AuthorWithComments = struct { id: u32, name: []const u8, posts: []const PostWithComments };

fn seedComments(comments: zom.Relation(CommentSchema, CountingGateway)) !void {
    _ = try comments.create(.{ .id = 100, .post_id = 10, .body = "Asante" }).commit();
    _ = try comments.create(.{ .id = 101, .post_id = 10, .body = "Nzuri sana" }).commit();
    _ = try comments.create(.{ .id = 102, .post_id = 12, .body = "Comptime!" }).commit();
    _ = try comments.create(.{ .id = 103, .post_id = 99, .body = "Orphan comment" }).commit();
}

test "nested combine: users -> posts -> comments, one query per level" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&f.gw);
    try seedComments(comments);
    const user_reads = &(try f.gw.dataset(UserSchema)).reads;
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;
    const comment_reads = &(try f.gw.dataset(CommentSchema)).reads;
    user_reads.* = 0;
    post_reads.* = 0;
    comment_reads.* = 0;

    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.order(.id, .asc).combine(.comments, comments.order(.id, .desc)))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(1, user_reads.*);
    try testing.expectEqual(1, post_reads.*);
    try testing.expectEqual(1, comment_reads.*);

    const authors = result.items;
    try testing.expectEqual(2, authors.len);
    try testing.expectEqualStrings("Achieng", authors[0].name);
    try testing.expectEqual(2, authors[0].posts.len);
    // Post 10's comments, in the comments relation's order (id desc).
    try testing.expectEqual(10, authors[0].posts[0].id);
    try testing.expectEqual(2, authors[0].posts[0].comments.len);
    try testing.expectEqualStrings("Nzuri sana", authors[0].posts[0].comments[0].body);
    try testing.expectEqualStrings("Asante", authors[0].posts[0].comments[1].body);
    try testing.expectEqual(0, authors[0].posts[1].comments.len);
    try testing.expectEqual(1, authors[1].posts.len);
    try testing.expectEqual(1, authors[1].posts[0].comments.len);
    try testing.expectEqualStrings("Comptime!", authors[1].posts[0].comments[0].body);
}

test "nested combine: the inner level reads only the outer level's rows, and none without keys" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&f.gw);
    try seedComments(comments);
    const comment_reads = &(try f.gw.dataset(CommentSchema)).reads;

    // Otieno's only post is 12: comment 102 is all the comments level sees.
    comment_reads.* = 0;
    var one = try f.users.byPk(2)
        .combine(.posts, f.posts.combine(.comments, comments))
        .mapTo(AuthorWithComments, testing.allocator);
    defer one.deinit();
    try testing.expectEqual(1, comment_reads.*);
    try testing.expectEqual(1, one.items[0].posts[0].comments.len);

    // No posts match, so the comments level has no keys and no query.
    comment_reads.* = 0;
    var none = try f.users.order(.id, .asc)
        .combine(.posts, f.posts.where(.id, .gt, 100).combine(.comments, comments))
        .mapTo(AuthorWithComments, testing.allocator);
    defer none.deinit();
    try testing.expectEqual(0, comment_reads.*);
    try testing.expectEqual(3, none.items.len);
    for (none.items) |a| try testing.expectEqual(0, a.posts.len);
}

test "nested combine: belongs-to inside has-many (users -> posts -> author)" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const Byline = struct { id: u32, author: ?struct { name: []const u8 } };
    const Writer2 = struct { name: []const u8, posts: []const Byline };
    var result = try f.users.byPk(1)
        .combine(.posts, f.posts.order(.id, .asc).combine(.author, f.users))
        .mapTo(Writer2, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(2, result.items[0].posts.len);
    for (result.items[0].posts) |p| try testing.expectEqualStrings("Achieng", p.author.?.name);
}

test "nested combine: each level makes ceil(keys / max_in) queries" {
    var gw: CountingGateway = .init(testing.allocator, .{});
    defer gw.deinit();
    const users: zom.Relation(UserSchema, CountingGateway) = try .init(&gw);
    const posts: zom.Relation(PostSchema, CountingGateway) = try .init(&gw);
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&gw);

    const max_in = zom.Query(PostTuple).max_in;
    // max_in + 3 users with two posts each: 2 user batches, and
    // 2 * (max_in + 3) post keys, so 3 post batches for the comments.
    const n_users = max_in + 3;
    for (0..n_users) |i| {
        const id: u32 = @intCast(i + 1);
        _ = try users.create(.{ .id = id, .name = "u", .email = "u@example.com", .age = 20 }).commit();
        for (0..2) |j| {
            const post_id: u32 = @intCast(2 * id + j);
            _ = try posts.create(.{ .id = post_id, .user_id = id, .title = "p", .published = true }).commit();
            _ = try comments.create(.{ .id = post_id, .post_id = post_id, .body = "c" }).commit();
        }
    }
    const post_reads = &(try gw.dataset(PostSchema)).reads;
    const comment_reads = &(try gw.dataset(CommentSchema)).reads;
    post_reads.* = 0;
    comment_reads.* = 0;

    var result = try users.order(.id, .asc)
        .combine(.posts, posts.order(.id, .asc).combine(.comments, comments))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();

    const divCeil = struct {
        fn f(n: usize, d: usize) usize {
            return std.math.divCeil(usize, n, d) catch unreachable;
        }
    }.f;
    try testing.expectEqual(divCeil(n_users, max_in), post_reads.*);
    try testing.expectEqual(divCeil(2 * n_users, max_in), comment_reads.*);
    try testing.expectEqual(n_users, result.items.len);
    for (result.items) |a| {
        try testing.expectEqual(2, a.posts.len);
        for (a.posts) |p| {
            try testing.expectEqual(1, p.comments.len);
            try testing.expectEqual(p.id, p.comments[0].id);
        }
    }
}

test "nested combine: each level pages its own parents, and the inner level reads only the kept rows" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&f.gw);
    try seedComments(comments);
    const comment_reads = &(try f.gw.dataset(CommentSchema)).reads;

    // Each user's first post, with that post's latest comment.
    comment_reads.* = 0;
    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.order(.id, .asc).limit(1).combine(.comments, comments.order(.id, .desc).limit(1)))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(1, comment_reads.*);
    const authors = result.items;
    try testing.expectEqual(2, authors.len);
    try testing.expectEqual(1, authors[0].posts.len);
    try testing.expectEqual(10, authors[0].posts[0].id);
    try testing.expectEqual(1, authors[0].posts[0].comments.len);
    try testing.expectEqualStrings("Nzuri sana", authors[0].posts[0].comments[0].body);
    try testing.expectEqual(12, authors[1].posts[0].id);
    try testing.expectEqualStrings("Comptime!", authors[1].posts[0].comments[0].body);

    // When the page keeps no posts, the comments level has no keys and reads nothing.
    comment_reads.* = 0;
    var none = try f.users.combine(.posts, f.posts.limit(0).combine(.comments, comments)).mapTo(AuthorWithComments, testing.allocator);
    defer none.deinit();
    try testing.expectEqual(0, comment_reads.*);
}

test "nested combine: one deinit frees the tree, also when allocation fails partway" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, zom.memory.Gateway) = try .init(&f.gw);
    _ = try comments.create(.{ .id = 100, .post_id = 10, .body = "Asante" }).commit();
    _ = try comments.create(.{ .id = 101, .post_id = 12, .body = "Comptime!" }).commit();
    const run = struct {
        fn run(
            allocator: std.mem.Allocator,
            users: zom.Relation(UserSchema, zom.memory.Gateway),
            posts: zom.Relation(PostSchema, zom.memory.Gateway),
            cs: zom.Relation(CommentSchema, zom.memory.Gateway),
        ) !void {
            var result = try users.combine(.posts, posts.combine(.comments, cs)).mapTo(AuthorWithComments, allocator);
            result.deinit();
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{ f.users, f.posts, comments });
}
