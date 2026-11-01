// expect: zom: adapter 'limited' cannot evaluate `reorder(.{ .{ .name, ... } })` on relation 'items': `supports.order_on` is false
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.LimitedGateway);

export fn entry() void {
    var gw = fakes.LimitedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.reorder(.{ .{ .id, .asc }, .{ .name, .desc } });
}
