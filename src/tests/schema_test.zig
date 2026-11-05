const std = @import("std");
const testing = std.testing;
const zom = @import("../root.zig");

const User = struct { id: u32, name: []const u8, manager_id: ?u32 = null };
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const Comment = struct { id: u64, post_id: u32, editor_id: ?u32 = null, body: []const u8 };

// Associations in both directions: UserSchema names PostSchema and
// PostSchema names UserSchema. The struct form keeps each association
// unevaluated until both declarations exist (see schema.zig).
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
        // Self-reference: a user manages other users.
        pub const reports = zom.hasMany(UserSchema, .manager_id);
        pub const manager = zom.belongsTo(UserSchema, .manager_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
        pub const comments = zom.hasMany(CommentSchema, .post_id);
    },
});
// The anonymous-struct form, fine when nothing points back at CommentSchema.
const CommentSchema = zom.Schema(Comment, "comments", .id, .{
    .associations = .{
        .post = zom.belongsTo(PostSchema, .post_id),
        .editor = zom.belongsTo(UserSchema, .editor_id),
    },
});

test "Schema: the 4-argument form with no associations" {
    const S = zom.Schema(Post, "posts", .id, .{});
    try testing.expectEqual(0, S.association_names.len);
    try testing.expectEqual(0, @typeInfo(@TypeOf(S.associations)).@"struct".fields.len);
    try testing.expectEqualStrings("posts", S.name);
    try testing.expect(S.primary_key == .id);
}

test "Schema: has-many and belongs-to referring to each other" {
    const posts = UserSchema.association(.posts);
    try testing.expectEqual(.has_many, posts.kind);
    try testing.expect(posts.source == UserSchema);
    try testing.expect(posts.target == PostSchema);
    try testing.expectEqualStrings("posts", posts.name);
    try testing.expectEqualStrings("user_id", posts.foreign_key);
    try testing.expectEqualStrings("id", posts.primary_key);
    try testing.expect(posts.Child() == PostSchema);
    try testing.expect(posts.Parent() == UserSchema);

    const author = PostSchema.association(.author);
    try testing.expectEqual(.belongs_to, author.kind);
    try testing.expect(author.source == PostSchema);
    try testing.expect(author.target == UserSchema);
    try testing.expectEqualStrings("user_id", author.foreign_key);
    try testing.expectEqualStrings("id", author.primary_key);
    try testing.expect(author.Child() == PostSchema);
    try testing.expect(author.Parent() == UserSchema);

    // Round trip through the cycle.
    try testing.expect(UserSchema.association(.posts).target.association(.author).target == UserSchema);
    try testing.expect(PostSchema.associations.author.target.associations.posts.target == PostSchema);
}

test "Schema: S.associations has one field per association, in order" {
    const fields = @typeInfo(@TypeOf(UserSchema.associations)).@"struct".fields;
    try testing.expectEqual(3, fields.len);
    inline for (.{ "posts", "reports", "manager" }, UserSchema.association_names, fields) |want, name, f| {
        try testing.expectEqualStrings(want, name);
        try testing.expectEqualStrings(want, f.name);
        try testing.expectEqualStrings(want, @field(UserSchema.associations, f.name).name);
    }
    try testing.expect(UserSchema.associations.posts.target == PostSchema);
}

test "Schema: self-reference" {
    const reports = UserSchema.association(.reports);
    try testing.expect(reports.target == UserSchema);
    try testing.expectEqualStrings("manager_id", reports.foreign_key);
    const manager = UserSchema.association(.manager);
    try testing.expectEqual(.belongs_to, manager.kind);
    try testing.expect(manager.target == UserSchema);
}

test "Schema: anonymous-struct associations and optional foreign keys" {
    const post = CommentSchema.association(.post);
    try testing.expectEqual(.belongs_to, post.kind);
    try testing.expect(post.target == PostSchema);
    try testing.expectEqualStrings("post_id", post.foreign_key);
    // Comment.editor_id is ?u32, pointing at User.id: u32.
    const editor = CommentSchema.association(.editor);
    try testing.expect(editor.target == UserSchema);
    try testing.expectEqualStrings("editor_id", editor.foreign_key);
    try testing.expectEqualStrings("id", editor.primary_key);
}

test "Schema: the descriptor drives a has-many lookup" {
    // What combine (#43) will do with it: match children to parents by
    // the association's keys instead of strings passed at each call.
    const a = UserSchema.association(.posts);
    const users = [_]User{ .{ .id = 1, .name = "Achieng" }, .{ .id = 2, .name = "Baraka" } };
    const posts = [_]Post{
        .{ .id = 10, .user_id = 2, .title = "b1" },
        .{ .id = 11, .user_id = 1, .title = "a1" },
        .{ .id = 12, .user_id = 2, .title = "b2" },
    };
    var counts = [_]usize{ 0, 0 };
    for (users, &counts) |u, *n| {
        for (posts) |p| {
            if (@field(p, a.foreign_key) == @field(u, a.primary_key)) n.* += 1;
        }
    }
    try testing.expectEqualSlices(usize, &.{ 1, 2 }, &counts);
}
