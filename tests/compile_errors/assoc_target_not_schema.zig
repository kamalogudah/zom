// expect: zom.hasMany: the target must be a zom.Schema type, found `assoc_target_not_schema.Post`
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };

const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = .{ .posts = zom.hasMany(Post, .user_id) },
});

export fn entry() void {
    _ = UserSchema;
}
