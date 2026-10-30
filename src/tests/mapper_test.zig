const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const Post = fixtures.Post;
const AuthorMapper = fixtures.AuthorMapper;
const Users = fixtures.Users;
const Posts = fixtures.Posts;
const seed = fixtures.seed;

test "map to entities and combine has-many" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
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
