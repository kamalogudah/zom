const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;

const Item = struct { id: u32, name: []const u8, odd: bool };
const ItemSchema = zom.Schema(Item, "items", .id, .{});
const Items = zom.Relation(ItemSchema, zom.memory.Gateway);

/// Seven items, so pages of 3 are full, full, then one row.
fn seed(gw: *zom.memory.Gateway) !Items {
    const items = try Items.init(gw);
    var i: u32 = 1;
    while (i <= 7) : (i += 1) _ = try items.create(.{ .id = i, .name = "item", .odd = i % 2 == 1 }).commit();
    return items;
}

fn expectIds(want: []const u32, got: []const Item) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqual(w, g.id);
}

fn expectPage(items: Items, n: usize, want_ids: []const u32) !void {
    const p = try items.order(.id, .asc).page(n).perPage(3).paginate(testing.allocator);
    defer p.free(testing.allocator);
    try expectIds(want_ids, p.rows);
    try testing.expectEqual(7, p.total);
    try testing.expectEqual(n, p.page);
    try testing.expectEqual(3, p.per_page);
    try testing.expectEqual(3, p.pages);
}

test "page 1" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    try expectPage(try seed(&gw), 1, &.{ 1, 2, 3 });
}

test "a middle page" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    try expectPage(try seed(&gw), 2, &.{ 4, 5, 6 });
}

test "the last page is partial" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    try expectPage(try seed(&gw), 3, &.{7});
}

test "a page past the end has no rows and the same total" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try seed(&gw);
    try expectPage(items, 4, &.{});
    try expectPage(items, 1000, &.{});
}

test "(n - 1) * k past usize is error.ValueOutOfRange" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try seed(&gw);
    const max = std.math.maxInt(usize);

    const p = items.page(max).perPage(2);
    try testing.expectError(error.ValueOutOfRange, p.offset());
    try testing.expectError(error.ValueOutOfRange, p.paginate(testing.allocator));
    try testing.expectError(error.ValueOutOfRange, p.toSlice(testing.allocator));

    // Right at the edge: (2 - 1) * max fits, and is past the end.
    const edge = try items.page(2).perPage(max).paginate(testing.allocator);
    defer edge.free(testing.allocator);
    try testing.expectEqual(0, edge.rows.len);
    try testing.expectEqual(7, edge.total);
    try testing.expectEqual(1, edge.pages);
}

test "page(n).perPage(k) is offset((n - 1) * k).limit(k)" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try seed(&gw);

    const rel = try items.page(3).perPage(2).paged();
    try testing.expectEqual(4, rel.query.offset);
    try testing.expectEqual(2, rel.query.limit);

    const rows = try items.order(.id, .desc).page(3).perPage(2).toSlice(testing.allocator);
    defer items.free(testing.allocator, rows);
    try expectIds(&.{ 3, 2 }, rows);

    // Runtime values work too.
    var n: usize = 2;
    var k: u8 = 4;
    _ = .{ &n, &k };
    const r = try items.page(n).perPage(k).paged();
    try testing.expectEqual(4, r.query.offset);
    try testing.expectEqual(4, r.query.limit);
}

test "the total counts the filtered query, without its own limit and offset" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try seed(&gw);

    // Odd ids: 1, 3, 5, 7. The earlier limit and offset are replaced.
    const p = try items.where(.odd, .eq, true).order(.id, .asc).limit(1).offset(3)
        .page(2).perPage(3).paginate(testing.allocator);
    defer p.free(testing.allocator);
    try expectIds(&.{7}, p.rows);
    try testing.expectEqual(4, p.total);
    try testing.expectEqual(2, p.pages);
}

test "an empty relation has no pages" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try Items.init(&gw);
    const p = try items.page(1).perPage(10).paginate(testing.allocator);
    defer p.free(testing.allocator);
    try testing.expectEqual(0, p.rows.len);
    try testing.expectEqual(0, p.total);
    try testing.expectEqual(0, p.pages);
}

test "a projected relation pages its projection" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try seed(&gw);
    const p = try items.select(.{.id}).order(.id, .asc).page(3).perPage(3).paginate(testing.allocator);
    defer p.free(testing.allocator);
    try testing.expectEqual(1, p.rows.len);
    try testing.expectEqual(7, p.rows[0].id);
    try testing.expectEqual(7, p.total);
}
