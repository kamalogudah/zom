// expect: zom.belongsTo: association 'author' of schema "posts": foreign key 'usr_id' is not a field of assoc_unknown_fk_belongs_to.Post (fields: id, user_id, title)
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };

const UserSchema = zom.Schema(User, "users", .id, .{});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = .{ .author = zom.belongsTo(UserSchema, .usr_id) },
});

export fn entry() void {
    _ = PostSchema;
}
