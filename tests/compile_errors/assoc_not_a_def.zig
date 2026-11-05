// expect: zom.Schema: association 'posts' must be zom.hasMany(...) or zom.belongsTo(...), found `@EnumLiteral()`
const zom = @import("zom");

const User = struct { id: u32 };

const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = .user_id;
    },
});

export fn entry() void {
    _ = UserSchema;
}
