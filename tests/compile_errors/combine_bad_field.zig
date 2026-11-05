// expect: zom.combine(.posts) on relation 'users': `combine_bad_field.Author`.posts must be a slice `[]const T`, found `?combine_bad_field.Post`
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const Author = struct { id: u32, posts: ?Post };
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{});

export fn entry() void {
    const std = @import("std");
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = zom.Relation(UserSchema, zom.memory.Gateway).init(&gw) catch return;
    const posts = zom.Relation(PostSchema, zom.memory.Gateway).init(&gw) catch return;
    _ = users.combine(.posts, posts).mapTo(Author, std.heap.page_allocator) catch return;
}
