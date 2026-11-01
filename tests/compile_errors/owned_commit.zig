// expect: zom: adapter 'owned' returns the stored tuple of relation 'items' with strings in an allocator; use `commitAlloc(allocator)`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.OwnedGateway);

export fn entry() void {
    var gw = fakes.OwnedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.create(.{ .id = 1 }).commit() catch return;
}
