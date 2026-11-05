// expect: zom: adapter 'readonly' cannot evaluate `whereJoined(.tags, .label, .eq, ...)` on relation 'tagged_items': `supports.join` is false
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.TaggedItemSchema, fakes.ReadOnlyGateway);

export fn entry() void {
    var gw = fakes.ReadOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.whereJoined(.tags, .label, .eq, "x");
}
