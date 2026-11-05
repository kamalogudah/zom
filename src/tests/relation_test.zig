const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const UserTuple = fixtures.UserTuple;
const Users = fixtures.Users;
const Posts = fixtures.Posts;
const seed = fixtures.seed;

test "relations are chainable and lazy" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    const posts = try Posts.init(&gw);
    try seed(users, posts);

    const over_25 = users.where(.age, .gt, 25).order(.name, .asc);
    try testing.expectEqual(@as(usize, 2), try over_25.count());

    const rows = try over_25.toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("Achieng", rows[0].name);
    try testing.expectEqualStrings("Wanjiru", rows[1].name);

    // The base relation is untouched by chaining.
    try testing.expectEqual(@as(usize, 3), try users.count());

    const page = try users.order(.age, .desc).offset(1).limit(1).toSlice(testing.allocator);
    defer testing.allocator.free(page);
    try testing.expectEqualStrings("Achieng", page[0].name);
}

test "enum and null filters" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    try testing.expectEqual(@as(usize, 1), try users.where(.role, .eq, .admin).count());
    try testing.expectEqual(@as(usize, 2), try users.where(.deleted_at, .eq, null).count());
}

test "one, first and byPk" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const otieno = (try users.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("Otieno", otieno.name);
    try testing.expectEqual(@as(?UserTuple, null), try users.byPk(99).one(testing.allocator));
    try testing.expectError(error.MoreThanOneTuple, users.one(testing.allocator));
    try testing.expect((try users.first(testing.allocator)) != null);
}

test "order puts nulls last on asc and first on desc" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    for ([_]?i64{ 3, null, 1, 2 }, 1..) |deleted_at, id| {
        _ = try users.create(.{ .id = @intCast(id), .name = "u", .email = "u@example.com", .age = 30, .deleted_at = deleted_at }).commit();
    }

    const asc = try users.order(.deleted_at, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(asc);
    try testing.expectEqualSlices(u32, &.{ 3, 4, 1, 2 }, &.{ asc[0].id, asc[1].id, asc[2].id, asc[3].id });

    const desc = try users.order(.deleted_at, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 4, 3 }, &.{ desc[0].id, desc[1].id, desc[2].id, desc[3].id });
}

const Priority = enum { low, medium, high };

const Task = struct {
    id: u32,
    priority: Priority,
    escalated_to: ?Priority = null,
};
const Tasks = zom.Relation(zom.Schema(Task, "tasks", .id, .{}), zom.memory.Gateway);

test "enums order and compare in declaration order" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const tasks = try Tasks.init(&gw);
    _ = try tasks.create(.{ .id = 1, .priority = .high, .escalated_to = .high }).commit();
    _ = try tasks.create(.{ .id = 2, .priority = .low }).commit();
    _ = try tasks.create(.{ .id = 3, .priority = .medium, .escalated_to = .medium }).commit();

    const asc = try tasks.order(.priority, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(asc);
    try testing.expectEqualSlices(Priority, &.{ .low, .medium, .high }, &.{ asc[0].priority, asc[1].priority, asc[2].priority });

    const desc = try tasks.order(.priority, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(desc);
    try testing.expectEqualSlices(Priority, &.{ .high, .medium, .low }, &.{ desc[0].priority, desc[1].priority, desc[2].priority });

    const above_low = try tasks.where(.priority, .gt, .low).order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(above_low);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, &.{ above_low[0].id, above_low[1].id });
    try testing.expectEqual(@as(usize, 2), try tasks.where(.priority, .lt, .high).count());
    try testing.expectEqual(@as(usize, 1), try tasks.where(.priority, .eq, .medium).count());
    try testing.expectEqual(@as(usize, 2), try tasks.where(.priority, .neq, .medium).count());

    // A runtime enum value goes through the same path as a literal.
    var p: Priority = .medium;
    _ = &p;
    try testing.expectEqual(@as(usize, 1), try tasks.where(.priority, .gte, p).where(.priority, .lt, .high).count());

    // Optional enums keep the null rules: ordering never matches null,
    // and nulls sort last on asc, first on desc.
    try testing.expectEqual(@as(usize, 2), try tasks.where(.escalated_to, .gt, .low).count());
    try testing.expectEqual(@as(usize, 1), try tasks.where(.escalated_to, .gt, .medium).count());
    try testing.expectEqual(@as(usize, 1), try tasks.where(.escalated_to, .eq, null).count());
    try testing.expectEqual(@as(usize, 2), try tasks.where(.escalated_to, .neq, null).count());

    const esc_asc = try tasks.order(.escalated_to, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(esc_asc);
    try testing.expectEqualSlices(u32, &.{ 3, 1, 2 }, &.{ esc_asc[0].id, esc_asc[1].id, esc_asc[2].id });

    const esc_desc = try tasks.order(.escalated_to, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(esc_desc);
    try testing.expectEqualSlices(u32, &.{ 2, 1, 3 }, &.{ esc_desc[0].id, esc_desc[1].id, esc_desc[2].id });
}

test "(age > 30 OR role = admin) AND deleted_at IS NULL on memory" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    // Achieng (31, admin) and Wanjiru (42) pass the OR; Wanjiru is deleted.
    const active_seniors = users.whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } }).where(.deleted_at, .is_null, {});
    const rows = try active_seniors.toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Achieng", rows[0].name);
    try testing.expectEqual(@as(usize, 1), try active_seniors.count());

    // NOT (deleted_at IS NULL OR age < 30): Wanjiru only.
    const old_deleted = users.whereNot(zom.any(.{ .{ .deleted_at, .is_null, {} }, .{ .age, .lt, 30 } }));
    try testing.expectEqualStrings("Wanjiru", (try old_deleted.one(testing.allocator)).?.name);

    // Writes go through the same tree.
    try testing.expectEqual(@as(usize, 2), try users.whereAny(.{ .{ .id, .eq, 2 }, .{ .id, .eq, 3 } }).delete());
    try testing.expectEqual(@as(usize, 1), try users.count());
}

test "copying a relation copies its query" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const a = users.whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } });
    var b = a;
    // Change the copy's query in place: turn the OR into an AND and the
    // first filter into age > 40. The original must not see either.
    const children = b.query.nodes[0].or_group;
    b.query.nodes[0] = .{ .and_group = children };
    b.query.filters[0].operand = .{ .one = .{ .int = 40 } };
    try testing.expectEqual(@as(usize, 0), try b.count());
    try testing.expectEqual(@as(usize, 2), try a.count());

    const c = a.where(.deleted_at, .is_null, {});
    try testing.expectEqual(@as(usize, 1), try c.count());
    try testing.expectEqual(@as(usize, 2), try a.count());
}
