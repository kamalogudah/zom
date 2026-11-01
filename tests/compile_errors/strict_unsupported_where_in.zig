// expect: zom: adapter 'readonly' cannot evaluate `whereIn(.id, ...)` on relation 'items': `.in` and `.not_in` filters need `supports.in`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.ReadOnlyGateway);

export fn entry() void {
    var gw = fakes.ReadOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    const ids = [_]u32{ 1, 2 };
    _ = items.whereIn(.id, &ids);
}
