const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const UserSchema = fixtures.Users.schema;
const PostSchema = fixtures.Posts.schema;

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway },
    .relations = .{ .users = .{ UserSchema, .default }, .posts = .{ PostSchema, .default } },
});

/// rom's `def active = where(deleted_at: nil)`, on a wrapper.
const Users = struct {
    rel: @FieldType(App.Relations, "users"),

    pub fn active(self: Users) @TypeOf(self.rel) {
        return self.rel.where(.deleted_at, .eq, null);
    }
};

const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users, .posts = .plain } });
const PlainRepo = zom.Repository(App, .{ .root = .posts, .relations = .{ .users, .posts } });

test "a repository with a custom view and root shortcuts on memory" {
    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();
    try fixtures.seed(app.relations.users, app.relations.posts);

    var repo = UserRepo.init(&app);
    try testing.expect(@TypeOf(repo.relations.users) == Users);
    try testing.expect(@TypeOf(repo.relations.posts) == fixtures.Posts);
    try testing.expect(UserRepo.RootRelation == fixtures.Users);

    // The view, through the field or through root().
    try testing.expectEqual(@as(usize, 2), try repo.relations.users.active().count());
    try testing.expectEqual(@as(usize, 1), try repo.root().active().where(.age, .gt, 30).count());

    // Read shortcuts.
    const u = (try repo.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("Otieno", u.name);
    try testing.expectEqual(@as(usize, 3), try repo.all().count());
    try testing.expectEqual(@as(usize, 1), try repo.where(.role, .eq, .admin).count());

    // Command shortcuts.
    _ = try repo.create(.{ .id = 4, .name = "Kamau", .email = "kamau@example.com", .age = 29 }).commit();
    _ = try repo.createMany(&.{
        .{ .id = 5, .name = "Njeri", .email = "njeri@example.com", .age = 35 },
        .{ .id = 6, .name = "Mutua", .email = "mutua@example.com", .age = 51 },
    }).commit();
    try testing.expectEqual(@as(usize, 6), try repo.all().count());

    try testing.expectEqual(@as(usize, 1), try repo.byPk(4).update().set(.age, 30).commit());
    try testing.expectEqual(@as(u8, 30), (try repo.byPk(4).one(testing.allocator)).?.age);

    try testing.expectEqual(@as(usize, 1), try repo.byPk(3).delete());
    try testing.expectEqual(@as(usize, 5), try repo.relations.users.active().count());

    // Other relations are reachable, and share the container's datasets.
    try testing.expectEqual(@as(usize, 3), try repo.relations.posts.count());
    try testing.expectEqual(app.relations.posts.dataset, repo.relations.posts.dataset);

    // An update of the whole root, then a delete of the whole root.
    try testing.expectEqual(@as(usize, 5), try repo.update().set(.role, .member).commit());
    try testing.expectEqual(@as(usize, 5), try repo.delete());
    try testing.expectEqual(@as(usize, 0), try repo.all().count());
}

test "a repository of plain relations, rooted elsewhere" {
    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();
    try fixtures.seed(app.relations.users, app.relations.posts);

    const repo = PlainRepo.init(&app);
    try testing.expect(PlainRepo.Root == fixtures.Posts);
    try testing.expectEqual(@as(usize, 2), try repo.where(.user_id, .eq, 1).count());
    try testing.expectEqual(@as(usize, 3), try repo.relations.users.count());
}
