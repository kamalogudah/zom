// expect: zom.association: 'labels' is not an association of schema "tagged_items" (associations: tags)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.TaggedItemSchema, fakes.JoinNoLikeGateway);

export fn entry() void {
    var gw = fakes.JoinNoLikeGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.join(.labels);
}
