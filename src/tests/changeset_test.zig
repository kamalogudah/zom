const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const Role = fixtures.Role;
const UserTuple = fixtures.UserTuple;
const Users = fixtures.Users;
const Posts = fixtures.Posts;
const seed = fixtures.seed;

fn promoteToAdmin(t: UserTuple) UserTuple {
    var next = t;
    next.role = .admin;
    return next;
}

test "create changeset with a map step" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    // Input buffer is reused right after commit; the dataset owns its copy.
    var name_buf = "Kamau".*;
    const stored = try users.create(.{ .id = 7, .name = &name_buf, .email = "kamau@example.com", .age = 29 })
        .map(promoteToAdmin)
        .commit();
    name_buf[0] = 'X';

    try testing.expectEqual(Role.admin, stored.role);
    const back = (try users.byPk(7).one(testing.allocator)).?;
    try testing.expectEqualStrings("Kamau", back.name);
}

test "update and delete" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const n = try users.byPk(2).update().set(.email, "o@example.com").set(.age, 25).commit();
    try testing.expectEqual(@as(usize, 1), n);
    const updated = (try users.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("o@example.com", updated.email);
    try testing.expectEqual(@as(u8, 25), updated.age);

    try testing.expectEqual(@as(usize, 1), try users.where(.deleted_at, .neq, null).delete());
    try testing.expectEqual(@as(usize, 2), try users.count());
}

test "out of range runtime values are rejected without partial writes" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    var age: u32 = 300;
    _ = &age;
    try testing.expectError(
        error.ValueOutOfRange,
        users.update().set(.email, "x@example.com").set(.age, age).commit(),
    );
    const achieng = (try users.byPk(1).one(testing.allocator)).?;
    try testing.expectEqualStrings("achieng@example.com", achieng.email);
    try testing.expectEqual(@as(u8, 31), achieng.age);
}

test "u64 above maxInt(u32) on a u32 attribute is rejected" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    var id: u64 = std.math.maxInt(u64);
    _ = &id;
    try testing.expectError(error.ValueOutOfRange, users.byPk(1).update().set(.id, id).commit());
    try testing.expectEqual(@as(usize, 1), try users.where(.id, .eq, 1).count());
}
