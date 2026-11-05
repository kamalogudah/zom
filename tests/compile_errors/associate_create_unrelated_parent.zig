// expect: zom: `associate(.author, ...)` on relation 'posts': the parent must be a
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
    },
});
const Users = zom.Relation(UserSchema, zom.memory.Gateway);
const Posts = zom.Relation(PostSchema, zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    const posts = Posts.init(&gw) catch return;
    _ = &users;
    _ = &posts;
    const other: Post = .{ .id = 1, .user_id = 1, .title = "not a user" };
    _ = posts.create(.{ .id = 2, .user_id = undefined, .title = "t" }).associate(.author, other).commit() catch return;
}
