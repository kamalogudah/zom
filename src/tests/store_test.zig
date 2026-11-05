//! `zom.memory.Store(S)` on its own, with no gateway or relation.

const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const UserTuple = @import("fixtures.zig").UserTuple;

const S = zom.Schema(UserTuple, "users", .id, .{});
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
    query.addOrder(.{ .field = .age, .direction = .desc });
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

// Sort keys `a` then `b`, with ties on `a` (including on null) broken by
// `b`, nulls on either side, and rows 1 and 8 equal on both keys.
const Pair = struct { id: u32, a: ?u8, b: ?u8 };
const PairStore = zom.memory.Store(zom.Schema(Pair, "pairs", .id, .{}));
const PairQ = zom.Query(Pair);
const pairs = [_]Pair{
    .{ .id = 1, .a = 1, .b = null },
    .{ .id = 2, .a = 1, .b = 5 },
    .{ .id = 3, .a = null, .b = 2 },
    .{ .id = 4, .a = 1, .b = 3 },
    .{ .id = 5, .a = null, .b = null },
    .{ .id = 6, .a = 2, .b = 3 },
    .{ .id = 7, .a = null, .b = 1 },
    .{ .id = 8, .a = 1, .b = null },
};

fn expectPairIds(store: *PairStore, query: PairQ, want: []const u32) !void {
    const rows = try store.read(query, testing.allocator);
    defer testing.allocator.free(rows);
    var ids: [pairs.len]u32 = undefined;
    for (rows, ids[0..rows.len]) |row, *id| id.* = row.id;
    try testing.expectEqualSlices(u32, want, ids[0..rows.len]);
}

test "read orders by several keys, the next one breaking ties, nulls last on asc" {
    var store = PairStore.init(testing.allocator);
    defer store.deinit();
    _ = try store.insertMany(&pairs);
    const q: PairQ = .{};

    // Nulls sort above every value: last on asc, first on desc, in either
    // key. Rows 1 and 8 tie on both keys and keep insertion order.
    try expectPairIds(&store, q.order(.a, .asc).order(.b, .asc), &.{ 4, 2, 1, 8, 6, 7, 3, 5 });
    try expectPairIds(&store, q.order(.a, .asc).order(.b, .desc), &.{ 1, 8, 2, 4, 6, 5, 3, 7 });
    try expectPairIds(&store, q.order(.a, .desc).order(.b, .asc), &.{ 7, 3, 5, 6, 4, 2, 1, 8 });
    try expectPairIds(&store, q.order(.a, .desc).order(.b, .desc), &.{ 5, 3, 7, 6, 1, 8, 2, 4 });
    // One key: ties keep insertion order (std.mem.sort is stable).
    try expectPairIds(&store, q.order(.a, .asc), &.{ 1, 2, 4, 8, 6, 3, 5, 7 });
    // A third key orders rows 1 and 8.
    try expectPairIds(&store, q.order(.a, .asc).order(.b, .asc).order(.id, .desc), &.{ 4, 2, 8, 1, 6, 7, 3, 5 });
    // No order: insertion order.
    try expectPairIds(&store, q, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
}

test "reorder replaces every sort key; order appends up to max_orders" {
    var store = PairStore.init(testing.allocator);
    defer store.deinit();
    _ = try store.insertMany(&pairs);
    const q: PairQ = .{};

    const by_id = q.order(.id, .desc);
    const re = by_id.reorder(.{ .{ .a, .desc }, .{ .b, .desc } });
    try testing.expectEqual(@as(usize, 2), re.orderSlice().len);
    try expectPairIds(&store, re, &.{ 5, 3, 7, 6, 1, 8, 2, 4 });
    // A runtime direction works.
    var dir: zom.Direction = .asc;
    _ = &dir;
    var by_b = by_id.reorder(.{.{ .b, dir }});
    by_b.limit = 3;
    try expectPairIds(&store, by_b, &.{ 7, 3, 4 });
    try expectPairIds(&store, by_id.reorder(.{}), &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    // The original is a value: reorder did not touch it.
    try testing.expectEqual(@as(usize, 1), by_id.orderSlice().len);

    const full = q.order(.a, .asc).order(.b, .asc).order(.id, .asc).order(.a, .desc);
    try testing.expectEqual(@as(usize, PairQ.max_orders), full.orderSlice().len);
}
