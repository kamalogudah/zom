// expect: zom.combine(.comments) on relation 'posts': `combine_nested_bad_field.PostWithComments`.comments must be a slice `[]const T`, found `?combine_nested_bad_field.Comment`
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const Comment = struct { id: u32, post_id: u32, body: []const u8 };
const PostWithComments = struct { id: u32, comments: ?Comment };
const Author = struct { id: u32, posts: []const PostWithComments };
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = struct {
        pub const comments = zom.hasMany(CommentSchema, .post_id);
    },
});
const CommentSchema = zom.Schema(Comment, "comments", .id, .{});

export fn entry() void {
    const std = @import("std");
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = zom.Relation(UserSchema, zom.memory.Gateway).init(&gw) catch return;
    const posts = zom.Relation(PostSchema, zom.memory.Gateway).init(&gw) catch return;
    const comments = zom.Relation(CommentSchema, zom.memory.Gateway).init(&gw) catch return;
    _ = users.combine(.posts, posts.combine(.comments, comments)).mapTo(Author, std.heap.page_allocator) catch return;
}
