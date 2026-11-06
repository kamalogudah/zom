// expect: zom.Schema("users"): unknown option 'assocations' (options: associations, plugins)
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };

const UserSchema = zom.Schema(User, "users", .id, .{ .assocations = .{} });

export fn entry() void {
    _ = UserSchema;
}
