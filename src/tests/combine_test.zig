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

test "combine: a paged target relation is refused" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();
    try testing.expectError(
        error.PagedCombineTarget,
        f.users.combine(.posts, f.posts.limit(1)).mapTo(Writer, testing.allocator),
    );
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
