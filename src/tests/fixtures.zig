const zom = @import("../root.zig");

pub const Role = enum { admin, member };

pub const UserTuple = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    age: u8,
    role: Role = .member,
    deleted_at: ?i64 = null,
};

pub const PostTuple = struct {
    id: u32,
    user_id: u32,
    title: []const u8,
    published: bool,
};

pub const Users = zom.Relation(zom.Schema(UserTuple, "users", .id, .{}), zom.memory.Gateway);
pub const Posts = zom.Relation(zom.Schema(PostTuple, "posts", .id, .{}), zom.memory.Gateway);

// Domain structs, decoupled from the tuples.
pub const Post = struct { id: u32, user_id: u32, title: []const u8 };
pub const Author = struct { id: u32, full_name: []const u8, posts: []const Post = &.{} };

pub const AuthorMapper = zom.Mapper(UserTuple, Author, .{
    .renames = &.{.{ .from = "name", .to = "full_name" }},
});

pub fn seed(users: Users, posts: Posts) !void {
    _ = try users.create(.{ .id = 1, .name = "Achieng", .email = "achieng@example.com", .age = 31, .role = .admin }).commit();
    _ = try users.create(.{ .id = 2, .name = "Otieno", .email = "otieno@example.com", .age = 24 }).commit();
    _ = try users.create(.{ .id = 3, .name = "Wanjiru", .email = "wanjiru@example.com", .age = 42, .deleted_at = 1_700_000_000 }).commit();

    _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values", .published = true }).commit();
    _ = try posts.create(.{ .id = 11, .user_id = 1, .title = "Mappers, not models", .published = false }).commit();
    _ = try posts.create(.{ .id = 12, .user_id = 2, .title = "Comptime schemas", .published = true }).commit();
}
