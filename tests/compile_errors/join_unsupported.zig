// expect: zom: adapter 'limited' cannot evaluate `join(.tags)` on relation 'tagged_items': `supports.join` is false
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.TaggedItemSchema, fakes.LimitedGateway);

export fn entry() void {
    var gw = fakes.LimitedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.join(.tags);
}
