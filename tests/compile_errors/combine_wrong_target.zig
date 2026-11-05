// expect: zom.combine(.posts) on relation 'users': the second argument must be a relation over schema "posts", found one over "users"
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{});
const Users = zom.Relation(UserSchema, zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.combine(.posts, users);
}
