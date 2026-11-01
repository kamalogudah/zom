//! `zom.memory.Store(S)` on its own, with no gateway or relation.

const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const UserTuple = @import("fixtures.zig").UserTuple;

const S = zom.Schema(UserTuple, "users", .id);
const Store = zom.memory.Store(S);
const Q = zom.Query(UserTuple);

fn user(id: u32, name: []const u8, age: u8) UserTuple {
    return .{ .id = id, .name = name, .email = "x@example.com", .age = age };
}

test "Store is the memory gateway's dataset" {
    try testing.expect(zom.memory.Gateway.Dataset(S) == Store);
    try testing.expect(zom.Adapter(zom.memory.Gateway).Dataset(S) == Store);
}

test "insert, read, count, update and delete without a gateway" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    _ = try store.insert(user(1, "Achieng", 31));
    _ = try store.insert(user(2, "Otieno", 24));
    try testing.expectEqual(@as(usize, 2), try store.insertMany(&.{ user(3, "Wanjiru", 42), user(4, "Kamau", 19) }));
    try testing.expectError(error.DuplicatePrimaryKey, store.insert(user(1, "Again", 1)));
    try testing.expectError(error.DuplicatePrimaryKey, store.insertMany(&.{ user(5, "A", 1), user(5, "B", 2) }));

    var query: Q = .{};
    query.addFilter(.{ .field = .age, .op = .gt, .operand = .{ .one = .{ .int = 20 } } });
    query.order = .{ .field = .age, .direction = .desc };
    const hits = try store.read(query, testing.allocator);
    defer testing.allocator.free(hits);
    try testing.expectEqual(@as(usize, 3), hits.len);
    try testing.expectEqualStrings("Wanjiru", hits[0].name);
    try testing.expectEqual(@as(usize, 3), try store.count(query));

    var by_id: Q = .{};
    by_id.addFilter(.{ .field = .id, .op = .eq, .operand = .{ .one = .{ .int = 2 } } });
    try testing.expectEqual(@as(usize, 1), try store.update(by_id, &.{.{ .field = .name, .value = .{ .string = "Otis" } }}));
    try testing.expectEqualStrings("Otis", store.rows()[1].name);

    try testing.expectEqual(@as(usize, 1), try store.delete(by_id));
    try testing.expectEqual(@as(usize, 3), try store.count(.{}));
}

test "rows returns every row in insertion order" {
    var store = Store.init(testing.allocator);
    defer store.deinit();
    try testing.expectEqual(@as(usize, 0), store.rows().len);

    _ = try store.insert(user(7, "Seven", 7));
    _ = try store.insert(user(3, "Three", 3));
    const all = store.rows();
    try testing.expectEqual(@as(usize, 2), all.len);
    try testing.expectEqual(@as(u32, 7), all[0].id);
    try testing.expectEqual(@as(u32, 3), all[1].id);
}

test "load and loadMany skip the primary-key check and copy strings" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    var name = "Kamau".*;
    _ = try store.load(user(1, &name, 1));
    _ = try store.load(user(1, &name, 2));
    try testing.expectEqual(@as(usize, 2), try store.loadMany(&.{ user(2, &name, 3), user(2, &name, 4) }));
    name[0] = 'X';

    try testing.expectEqual(@as(usize, 4), store.rows().len);
    for (store.rows()) |row| try testing.expectEqualStrings("Kamau", row.name);
    // insert still checks against loaded rows.
    try testing.expectError(error.DuplicatePrimaryKey, store.insert(user(2, "Again", 5)));
}

test "clear drops every row and the store can be refilled" {
    var store = Store.init(testing.allocator);
    defer store.deinit();

    const long = "n" ** 4096;
    _ = try store.insertMany(&.{ user(1, long, 1), user(2, long, 2) });
    store.clear();
    try testing.expectEqual(@as(usize, 0), store.rows().len);
    try testing.expectEqual(@as(usize, 0), try store.count(.{}));

    // The keys are free again.
    _ = try store.insert(user(1, "Again", 1));
    try testing.expectEqualStrings("Again", store.rows()[0].name);
}

fn loadManyUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var store = Store.init(allocator);
    defer store.deinit();
    _ = try store.insert(user(1, "First", 1));

    const long = "n" ** 4096;
    const n = store.loadMany(&.{ user(2, long, 2), user(3, long, 3), user(4, long, 4) }) catch |err| {
        try testing.expectEqual(@as(usize, 1), store.rows().len);
        return err;
    };
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(usize, 4), store.rows().len);
}

test "a loadMany that runs out of memory loads nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, loadManyUnderAllocationFailure, .{});
}

fn loadUnderAllocationFailure(allocator: std.mem.Allocator) !void {
    var store = Store.init(allocator);
    defer store.deinit();
    _ = store.load(user(1, "n" ** 4096, 1)) catch |err| {
        try testing.expectEqual(@as(usize, 0), store.rows().len);
        return err;
    };
    try testing.expectEqual(@as(usize, 1), store.rows().len);
}

test "a load that runs out of memory stores nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, loadUnderAllocationFailure, .{});
}
