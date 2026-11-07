const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const build_options = @import("build_options");

const Post = fixtures.Post;
const AuthorMapper = fixtures.AuthorMapper;
const Users = fixtures.Users;
const Posts = fixtures.Posts;
const seed = fixtures.seed;

// combine_test.zig covers the same data through `relation.combine`. This
// test keeps the deprecated path working until combineMany is removed.
test "deprecated combineMany still combines has-many" {
    if (build_options.no_deprecated) return error.SkipZigTest;
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    const posts = try Posts.init(&gw);
    try seed(users, posts);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const authors = try users.where(.deleted_at, .eq, null).order(.id, .asc).mapWith(AuthorMapper, a);
    const author_posts = try posts.where(.published, .eq, true).order(.id, .asc).mapTo(Post, a);
    try zom.combineMany(.{ .into = "posts", .parent_key = "id", .child_key = "user_id" }, a, authors, author_posts);

    try testing.expectEqual(@as(usize, 2), authors.len);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
    try testing.expectEqual(@as(usize, 1), authors[0].posts.len);
    try testing.expectEqualStrings("Relations are values", authors[0].posts[0].title);
    try testing.expectEqualStrings("Comptime schemas", authors[1].posts[0].title);
}

test "isMapper tells a zom.Mapper from a hand-written one" {
    const Hand = struct {
        pub const Input = fixtures.UserTuple;
        pub const Output = Post;
        pub const options: zom.mapper.Options = .{};
        pub fn call(_: fixtures.UserTuple) Post {
            return undefined;
        }
    };
    try testing.expect(zom.mapper.isMapper(AuthorMapper));
    try testing.expect(zom.mapper.isMapper(zom.Mapper(fixtures.PostTuple, Post, .{})));
    try testing.expect(!zom.mapper.isMapper(Hand));
    try testing.expect(!zom.mapper.isMapper(u32));
}
