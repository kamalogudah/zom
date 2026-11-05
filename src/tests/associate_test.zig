const std = @import("std");
const testing = std.testing;
const zom = @import("../root.zig");
const fixtures = @import("fixtures.zig");

const UserTuple = fixtures.UserTuple;
const PostTuple = fixtures.PostTuple;

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

/// Two belongsTo associations, one with an optional key.
const CommentTuple = struct {
    id: u32,
    post_id: u32,
    user_id: ?u32 = null,
    body: []const u8,
};
const CommentSchema = zom.Schema(CommentTuple, "comments", .id, .{
    .associations = struct {
        pub const post = zom.belongsTo(PostSchema, .post_id);
        pub const author = zom.belongsTo(UserSchema, .user_id);
    },
});

const Users = zom.Relation(UserSchema, zom.memory.Gateway);
const Posts = zom.Relation(PostSchema, zom.memory.Gateway);
const Comments = zom.Relation(CommentSchema, zom.memory.Gateway);

const Fixture = struct {
    gw: zom.memory.Gateway,
    users: Users,
    posts: Posts,
    comments: Comments,

    fn init(self: *Fixture) !void {
        self.gw = .init(testing.allocator, .{});
        errdefer self.gw.deinit();
        self.users = try .init(&self.gw);
        self.posts = try .init(&self.gw);
        self.comments = try .init(&self.gw);
        _ = try self.users.create(.{ .id = 1, .name = "Achieng", .email = "achieng@example.com", .age = 31 }).commit();
        _ = try self.users.create(.{ .id = 2, .name = "Otieno", .email = "otieno@example.com", .age = 24 }).commit();
    }

    fn deinit(self: *Fixture) void {
        self.gw.deinit();
    }
};

const Writer = struct { id: u32, name: []const u8, posts: []const PostTuple };

test "associate: a post created under its author reads back through combine" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const author = (try f.users.byPk(1).one(testing.allocator)).?;
    const stored = try f.posts.associate(.author, author)
        .create(.{ .id = 13, .title = "Changesets", .published = true })
        .commit();
    try testing.expectEqual(1, stored.user_id);

    var result = try f.users.byPk(1).combine(.posts, f.posts).mapTo(Writer, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(1, result.items.len);
    try testing.expectEqual(1, result.items[0].posts.len);
    try testing.expectEqual(13, result.items[0].posts[0].id);
    try testing.expectEqualStrings("Changesets", result.items[0].posts[0].title);
}

test "associate: Input is the tuple without the key, and keeps result types" {
    const Scoped = zom.changeset.Scoped(Posts, zom.changeset.withKey(Posts, .{}, .author, UserTuple));
    try testing.expect(!@hasField(Scoped.Input, "user_id"));
    try testing.expect(@hasField(Scoped.Input, "title"));

    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const author = (try f.users.byPk(2).one(testing.allocator)).?;
    var n: usize = 20;
    _ = &n;
    // `@intCast` needs the field's type as its result type.
    _ = try f.posts.associate(.author, author).create(.{ .id = @intCast(n), .title = "Typed", .published = false }).commit();
    try testing.expectEqual(2, (try f.posts.byPk(20).one(testing.allocator)).?.user_id);
}

test "associate: the parent may be a select of the target that kept the key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const author = (try f.users.byPk(2).select(.{ .id, .name }).one(testing.allocator)).?;
    _ = try f.posts.associate(.author, author).create(.{ .id = 14, .title = "Projected", .published = true }).commit();
    try testing.expectEqual(2, (try f.posts.byPk(14).one(testing.allocator)).?.user_id);
}

test "associate: ROM's order overwrites the key on a whole tuple" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const author = (try f.users.byPk(2).one(testing.allocator)).?;
    const stored = try f.posts.create(.{ .id = 15, .user_id = undefined, .title = "Late key", .published = true })
        .associate(.author, author)
        .commit();
    try testing.expectEqual(2, stored.user_id);
}

test "associate: chained associations, with an optional key" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const author = (try f.users.byPk(2).one(testing.allocator)).?;
    const post = try f.posts.associate(.author, (try f.users.byPk(1).one(testing.allocator)).?)
        .create(.{ .id = 10, .title = "Hello", .published = true }).commit();

    const scoped = f.comments.associate(.post, post).associate(.author, author);
    try testing.expect(!@hasField(@TypeOf(scoped).Input, "post_id"));
    try testing.expect(!@hasField(@TypeOf(scoped).Input, "user_id"));
    const c = try scoped.create(.{ .id = 1, .body = "First" }).commit();
    try testing.expectEqual(10, c.post_id);
    try testing.expectEqual(@as(?u32, 2), c.user_id);
}

test "associate: createMany under a parent, and createMany(...).associate" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const achieng = (try f.users.byPk(1).one(testing.allocator)).?;
    const otieno = (try f.users.byPk(2).one(testing.allocator)).?;

    const scoped = f.posts.associate(.author, achieng);
    const rows = [_]@TypeOf(scoped).Input{
        .{ .id = 30, .title = "One", .published = true },
        .{ .id = 31, .title = "Two", .published = false },
    };
    try testing.expectEqual(2, try scoped.createMany(&rows).commitAlloc(testing.allocator));

    const whole = [_]PostTuple{
        .{ .id = 32, .user_id = undefined, .title = "Three", .published = true },
        .{ .id = 33, .user_id = undefined, .title = "Four", .published = true },
    };
    try testing.expectEqual(2, try f.posts.createMany(&whole).associate(.author, otieno).commitAlloc(testing.allocator));

    // An empty batch inserts nothing.
    try testing.expectEqual(0, try scoped.createMany(&.{}).commitAlloc(testing.allocator));

    var result = try f.users.order(.id, .asc).combine(.posts, f.posts.order(.id, .asc)).mapTo(Writer, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(2, result.items[0].posts.len);
    try testing.expectEqual(30, result.items[0].posts[0].id);
    try testing.expectEqual(31, result.items[0].posts[1].id);
    try testing.expectEqual(2, result.items[1].posts.len);
    try testing.expectEqual(32, result.items[1].posts[0].id);
    try testing.expectEqual(33, result.items[1].posts[1].id);
}
