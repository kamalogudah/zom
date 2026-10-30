const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const UserTuple = fixtures.UserTuple;
const Users = fixtures.Users;

test "sql compiler renders the same relation as a statement" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    const rel = users.where(.age, .gte, 18).where(.deleted_at, .eq, null).where(.role, .eq, .admin)
        .order(.name, .desc).limit(10).offset(20);
    const compiled = try zom.sql.compileSelect(UserTuple, testing.allocator, Users.schema.name, rel.query);
    defer compiled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "SELECT \"id\", \"name\", \"email\", \"age\", \"role\", \"deleted_at\" FROM \"users\" WHERE \"age\" >= $1 AND \"deleted_at\" IS NULL AND \"role\" = $2 ORDER BY \"name\" DESC LIMIT 10 OFFSET 20",
        compiled.sql,
    );
    try testing.expectEqual(@as(usize, 2), compiled.params.len);
    try testing.expectEqual(@as(i64, 18), compiled.params[0].int);
    try testing.expectEqualStrings("admin", compiled.params[1].string);
}

test "sql compiler renders the largest limit and offset in full" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    const max = std.math.maxInt(usize);
    const rel = users.limit(max).offset(max);
    const compiled = try zom.sql.compileSelect(UserTuple, testing.allocator, Users.schema.name, rel.query);
    defer compiled.deinit(testing.allocator);

    var expected: [128]u8 = undefined;
    try testing.expectEqualStrings(
        try std.fmt.bufPrint(&expected, "SELECT \"id\", \"name\", \"email\", \"age\", \"role\", \"deleted_at\" FROM \"users\" LIMIT {d} OFFSET {d}", .{ max, max }),
        compiled.sql,
    );
}

test "sql compiler quotes reserved words and mixed case" {
    const Row = struct { id: u32, order: u32, createdAt: i64 };
    var query: zom.Query(Row) = .{};
    query.addFilter(.{ .field = .order, .op = .eq, .value = .{ .int = 1 } });
    query.order = .{ .field = .createdAt, .direction = .asc };
    const compiled = try zom.sql.compileSelect(Row, testing.allocator, "user", query);
    defer compiled.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "SELECT \"id\", \"order\", \"createdAt\" FROM \"user\" WHERE \"order\" = $1 ORDER BY \"createdAt\" ASC",
        compiled.sql,
    );
}

test "writeIdent doubles embedded quotes" {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(testing.allocator);

    try zom.sql.writeIdent(&list, testing.allocator, "a\"b");
    try testing.expectEqualStrings("\"a\"\"b\"", list.items);

    list.clearRetainingCapacity();
    try zom.sql.writeIdent(&list, testing.allocator, "users\"; DROP TABLE users; --");
    try testing.expectEqualStrings("\"users\"\"; DROP TABLE users; --\"", list.items);
}
