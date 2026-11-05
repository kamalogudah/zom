// expect: zom.belongsTo: association 'author' of schema "posts": foreign key assoc_fk_type_mismatch.Post.user_id is `i64`, but the key it points at, assoc_fk_type_mismatch.User.id, is `u32` (expected `u32` or `?u32`)
// expect: zom.hasMany: association 'posts' of schema "users": foreign key assoc_fk_type_mismatch.Post.user_id is `i64`
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: i64, title: []const u8 };

// Both directions, so the mismatch is caught on the cyclic form too.
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

export fn entry() void {
    _ = UserSchema;
}
