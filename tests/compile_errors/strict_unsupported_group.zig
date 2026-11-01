// expect: zom: adapter 'limited' cannot evaluate `whereAny(...)` on relation 'items': boolean groups (`whereAny`, `whereNot`) need `supports.or`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.LimitedGateway);

export fn entry() void {
    var gw = fakes.LimitedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.whereAny(.{ .{ .id, .eq, 1 }, .{ .id, .eq, 2 } });
}
