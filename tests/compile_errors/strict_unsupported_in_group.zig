// expect: zom: adapter 'oronly' cannot evaluate `whereNot(...) with .id, .in` on relation 'items': `.in` and `.not_in` filters need `supports.in`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.OrOnlyGateway);

export fn entry() void {
    var gw = fakes.OrOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // The group is supported; the `in` nested inside it is not.
    _ = items.whereNot(zom.any(.{ .{ .name, .eq, "x" }, .{ .id, .in, .{ 1, 2 } } }));
}
