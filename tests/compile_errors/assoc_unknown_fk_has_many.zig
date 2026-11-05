// expect: zom.hasMany: association 'posts' of schema "users": foreign key 'author_id' is not a field of assoc_unknown_fk_has_many.Post (fields: id, user_id, title)
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };

const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .author_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{});

export fn entry() void {
    _ = UserSchema;
}
