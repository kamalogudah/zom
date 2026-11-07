const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const Users = fixtures.Users;
const Posts = fixtures.Posts;
const seed = fixtures.seed;

test "primary key is unique on create and update" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    try testing.expectError(
        error.DuplicatePrimaryKey,
        users.create(.{ .id = 1, .name = "Again", .email = "again@example.com", .age = 20 }).commit(),
    );
    try testing.expectError(error.DuplicatePrimaryKey, users.byPk(2).update().set(.id, 1).commit());
    try testing.expectError(error.DuplicatePrimaryKey, users.update().set(.id, 9).commit());

    // Moving one row to a free key is fine.
    try testing.expectEqual(@as(usize, 1), try users.byPk(2).update().set(.id, 9).commit());
    try testing.expectEqual(@as(usize, 3), try users.count());
}

const Counter = struct { id: u64, n: u64 };
const Counters = zom.Relation(zom.Schema(Counter, "counters", .id, .{}), zom.memory.Gateway);

test "u64 values above maxInt(i64) round-trip" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const counters = try Counters.init(&gw);

    const max = std.math.maxInt(u64);
    const big: u64 = std.math.maxInt(i64) + 1;
    _ = try counters.create(.{ .id = max, .n = 1 }).commit();
    _ = try counters.create(.{ .id = big, .n = 2 }).commit();
    _ = try counters.create(.{ .id = 1, .n = 3 }).commit();
    try testing.expectError(error.DuplicatePrimaryKey, counters.create(.{ .id = max, .n = 4 }).commit());

    try testing.expectEqual(@as(u64, 1), (try counters.where(.id, .eq, max).one(testing.allocator)).?.n);
    try testing.expectEqual(@as(usize, 2), try counters.where(.id, .gt, std.math.maxInt(i64)).count());
    try testing.expectEqual(@as(usize, 3), try counters.where(.id, .gte, 0).count());

    const rows = try counters.order(.id, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(u64, &.{ max, big, 1 }, &.{ rows[0].id, rows[1].id, rows[2].id });

    try testing.expectEqual(@as(usize, 1), try counters.byPk(big).update().set(.n, max).commit());
    try testing.expectEqual(max, (try counters.byPk(big).one(testing.allocator)).?.n);
}

test "int and uint values compare across variants" {
    try testing.expectEqual(std.math.Order.lt, zom.Value.order(.{ .int = -1 }, .{ .uint = 0 }).?);
    try testing.expectEqual(std.math.Order.gt, zom.Value.order(.{ .uint = 0 }, .{ .int = -1 }).?);
    try testing.expectEqual(std.math.Order.eq, zom.Value.order(.{ .int = 5 }, .{ .uint = 5 }).?);
    try testing.expectEqual(std.math.Order.lt, zom.Value.order(.{ .int = std.math.maxInt(i64) }, .{ .uint = std.math.maxInt(u64) }).?);
    try testing.expectEqual(std.math.Order.gt, zom.Value.order(.{ .uint = std.math.maxInt(u64) }, .{ .float = 1.0 }).?);
    try testing.expectEqual(std.math.Order.lt, zom.Value.order(.{ .float = -1.0 }, .{ .uint = 0 }).?);
}

const Account = struct { id: u128, user_data_128: u128 = 0, ledger: u32 = 1 };
const Accounts = zom.Relation(zom.Schema(Account, "accounts", .id, .{}), zom.memory.Gateway);

test "u128 values: where, order, byPk and update on memory" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const accounts = try Accounts.init(&gw);

    const max = std.math.maxInt(u128);
    const mid: u128 = std.math.maxInt(u64) + 1;
    _ = try accounts.create(.{ .id = max, .user_data_128 = 1 }).commit();
    _ = try accounts.create(.{ .id = mid, .user_data_128 = 2 }).commit();
    _ = try accounts.create(.{ .id = 3, .user_data_128 = 3 }).commit();
    try testing.expectError(error.DuplicatePrimaryKey, accounts.create(.{ .id = max }).commit());

    try testing.expectEqual(@as(u128, 1), (try accounts.where(.id, .eq, std.math.maxInt(u128)).one(testing.allocator)).?.user_data_128);
    try testing.expectEqual(@as(usize, 2), try accounts.where(.id, .gt, std.math.maxInt(u64)).count());
    try testing.expectEqual(@as(usize, 1), try accounts.where(.id, .lt, std.math.maxInt(i64)).count());
    // A u128 attribute compared with a literal that fits i64 still matches.
    try testing.expectEqual(@as(usize, 1), try accounts.where(.id, .eq, 3).count());

    const rows = try accounts.order(.id, .desc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualSlices(u128, &.{ max, mid, 3 }, &.{ rows[0].id, rows[1].id, rows[2].id });

    try testing.expectEqual(@as(usize, 1), try accounts.byPk(mid).update().set(.user_data_128, max).commit());
    try testing.expectEqual(max, (try accounts.byPk(mid).one(testing.allocator)).?.user_data_128);
    // A runtime u128 too big for the u32 attribute is refused on commit.
    var too_big: u128 = max;
    _ = &too_big;
    try testing.expectError(error.ValueOutOfRange, accounts.byPk(3).update().set(.ledger, too_big).commit());
}

test "toValue: u65..u128 types and literals past u64 are uint128" {
    try testing.expectEqual(zom.Value{ .uint128 = 5 }, zom.query.toValue(@as(u128, 5)));
    try testing.expectEqual(zom.Value{ .uint128 = 5 }, zom.query.toValue(@as(u65, 5)));
    try testing.expectEqual(zom.Value{ .uint128 = std.math.maxInt(u128) }, zom.query.toValue(std.math.maxInt(u128)));
    try testing.expectEqual(zom.Value{ .uint = std.math.maxInt(u64) }, zom.query.toValue(std.math.maxInt(u64)));
    try testing.expectEqual(zom.Value{ .uint128 = std.math.maxInt(u64) + 1 }, zom.query.toValue(std.math.maxInt(u64) + 1));
    try testing.expectEqual(@as(u128, std.math.maxInt(u128)), try zom.query.fromValue(u128, .{ .uint128 = std.math.maxInt(u128) }));
    try testing.expectEqual(@as(u128, 7), try zom.query.fromValue(u128, .{ .int = 7 }));
    try testing.expectError(error.ValueOutOfRange, zom.query.fromValue(u128, .{ .int = -1 }));
    try testing.expectError(error.ValueOutOfRange, zom.query.fromValue(u64, .{ .uint128 = std.math.maxInt(u64) + 1 }));
    try testing.expectEqual(@as(?u128, null), try zom.query.fromValue(?u128, .null));
}

test "uint128 orders against int, uint and float, including negative ints" {
    const Order = std.math.Order;
    const V = zom.Value;
    const max128: V = .{ .uint128 = std.math.maxInt(u128) };
    const min_int: V = .{ .int = std.math.minInt(i64) };
    const cases = [_]struct { V, V, Order }{
        .{ .{ .int = -1 }, .{ .uint128 = 0 }, .lt },
        .{ min_int, max128, .lt },
        .{ .{ .uint128 = 0 }, .{ .int = -1 }, .gt },
        .{ .{ .uint128 = 5 }, .{ .int = 5 }, .eq },
        .{ .{ .uint128 = 5 }, .{ .uint = 5 }, .eq },
        .{ .{ .uint = std.math.maxInt(u64) }, .{ .uint128 = std.math.maxInt(u64) + 1 }, .lt },
        .{ .{ .int = std.math.maxInt(i64) }, .{ .uint128 = std.math.maxInt(i64) }, .eq },
        .{ max128, .{ .uint = std.math.maxInt(u64) }, .gt },
        .{ max128, max128, .eq },
        .{ .{ .uint128 = std.math.maxInt(u128) - 1 }, max128, .lt },
        .{ max128, .{ .float = 1.0 }, .gt },
        .{ .{ .float = -1.0 }, .{ .uint128 = 0 }, .lt },
        .{ .{ .float = 1e39 }, max128, .gt },
    };
    for (cases) |c| {
        errdefer std.debug.print("order({any}, {any})\n", .{ c[0], c[1] });
        try testing.expectEqual(c[2], c[0].order(c[1]).?);
        try testing.expectEqual(c[2].invert(), c[1].order(c[0]).?);
        try testing.expectEqual(c[2] == .eq, c[0].eql(c[1]));
    }
    try testing.expectEqual(null, max128.order(.{ .string = "1" }));
    try testing.expectEqual(null, max128.order(.null));
    try testing.expectEqual(null, max128.order(.{ .boolean = true }));
    try testing.expect(!max128.eql(.null));
}

test "uint128 does not grow Value" {
    // u128 is 16-byte aligned on x86_64; the payload is stored at 8, so the
    // largest variant is still the 16-byte string slice, plus the tag.
    if (@sizeOf(usize) == 8) try testing.expectEqual(24, @sizeOf(zom.Value));
    try testing.expectEqual(@alignOf([]const u8), @alignOf(zom.Value));
}

const Contact = struct {
    id: u32,
    name: [:0]const u8,
    handle: []u8,
    nickname: ?[:0]const u8 = null,
};
const Contacts = zom.Relation(zom.Schema(Contact, "contacts", .id, .{}), zom.memory.Gateway);

test "every string type is copied on insert and update" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const contacts = try Contacts.init(&gw);

    const name = try testing.allocator.dupeSentinel(u8, "Achieng", 0);
    defer testing.allocator.free(name);
    const handle = try testing.allocator.dupe(u8, "achieng");
    defer testing.allocator.free(handle);
    const nickname = try testing.allocator.dupeSentinel(u8, "Chi", 0);
    defer testing.allocator.free(nickname);

    _ = try contacts.create(.{ .id = 1, .name = name, .handle = handle, .nickname = nickname }).commit();
    _ = try contacts.create(.{ .id = 2, .name = name, .handle = handle }).commit();
    // The allocator does not catch use-after-free, so clobber the buffers instead.
    @memset(name, 'x');
    @memset(handle, 'x');
    @memset(nickname, 'x');

    const first = (try contacts.byPk(1).one(testing.allocator)).?;
    try testing.expectEqualStrings("Achieng", first.name);
    try testing.expectEqual(@as(u8, 0), first.name[first.name.len]);
    try testing.expectEqualStrings("achieng", first.handle);
    try testing.expectEqualStrings("Chi", first.nickname.?);
    try testing.expectEqual(@as(u8, 0), first.nickname.?[first.nickname.?.len]);
    try testing.expectEqual(@as(?[:0]const u8, null), (try contacts.byPk(2).one(testing.allocator)).?.nickname);

    const renamed = try testing.allocator.dupe(u8, "Otieno");
    defer testing.allocator.free(renamed);
    try testing.expectEqual(@as(usize, 1), try contacts.byPk(2).update()
        .set(.name, renamed).set(.handle, renamed).set(.nickname, renamed).commit());
    @memset(renamed, 'x');

    const second = (try contacts.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("Otieno", second.name);
    try testing.expectEqual(@as(u8, 0), second.name[second.name.len]);
    try testing.expectEqualStrings("Otieno", second.handle);
    try testing.expectEqualStrings("Otieno", second.nickname.?);

    try testing.expectEqual(@as(usize, 1), try contacts.byPk(1).update().set(.nickname, null).commit());
    try testing.expectEqual(@as(?[:0]const u8, null), (try contacts.byPk(1).one(testing.allocator)).?.nickname);
}

fn updateUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const before = try users.order(.id, .asc).toSlice(allocator);
    defer allocator.free(before);

    // Long enough that every copy needs a fresh arena buffer.
    const name = &@as([4096]u8, @splat('n'));
    const changed = users.update().set(.name, name).set(.email, name).commit() catch |err| {
        const after = try users.order(.id, .asc).toSlice(testing.allocator);
        defer testing.allocator.free(after);
        try testing.expectEqualDeep(before, after);
        return err;
    };
    try testing.expectEqual(@as(usize, 3), changed);
    try testing.expectEqual(@as(usize, 3), try users.where(.name, .eq, name).where(.email, .eq, name).count());
}

test "an update that runs out of memory leaves the dataset unchanged" {
    try testing.checkAllAllocationFailures(testing.allocator, updateUnderAllocationFailure, .{});
}

test "insertMany with a duplicate key inserts nothing" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const new: fixtures.UserTuple = .{ .id = 4, .name = "Kamau", .email = "kamau@example.com", .age = 29 };
    const clash: fixtures.UserTuple = .{ .id = 2, .name = "Again", .email = "again@example.com", .age = 30 };

    // Against a stored row, even when the clash comes after a new row.
    try testing.expectError(error.DuplicatePrimaryKey, users.createMany(&.{ new, clash }).commit());
    try testing.expectEqual(@as(usize, 3), try users.count());
    try testing.expectEqual(@as(usize, 0), try users.byPk(4).count());

    // Inside the batch.
    var twin = new;
    twin.name = "Twin";
    try testing.expectError(error.DuplicatePrimaryKey, users.createMany(&.{ new, twin }).commit());
    try testing.expectEqual(@as(usize, 3), try users.count());

    // The memory adapter has insertMany, so this went through it, not the loop.
    try testing.expect(comptime Users.Adapter.has(Users.schema, .batch_insert));
}

test "insertMany copies strings so the batch can be reused" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    var name = "Kamau".*;
    var rows = [_]fixtures.UserTuple{
        .{ .id = 1, .name = &name, .email = "a@example.com", .age = 1 },
        .{ .id = 2, .name = &name, .email = "b@example.com", .age = 2 },
    };
    try testing.expectEqual(@as(usize, 2), try users.createMany(&rows).commit());
    name[0] = 'X';
    rows[0].id = 99;
    try testing.expectEqualStrings("Kamau", (try users.byPk(1).one(testing.allocator)).?.name);
    try testing.expectEqualStrings("Kamau", (try users.byPk(2).one(testing.allocator)).?.name);
}

fn insertManyUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    // Long enough that every copy needs a fresh arena buffer.
    const long = &@as([4096]u8, @splat('n'));
    const batch = [_]fixtures.UserTuple{
        .{ .id = 4, .name = long, .email = long, .age = 1 },
        .{ .id = 5, .name = long, .email = long, .age = 2 },
        .{ .id = 6, .name = long, .email = long, .age = 3 },
    };
    const n = users.createMany(&batch).commit() catch |err| {
        try testing.expectEqual(@as(usize, 3), try users.count());
        try testing.expectEqual(@as(usize, 0), try users.where(.id, .gt, 3).count());
        return err;
    };
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 6), try users.count());
}

test "an insertMany that runs out of memory inserts nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, insertManyUnderAllocationFailure, .{});
}
