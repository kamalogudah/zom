// expect: zom: adapter 'joinnolike' cannot evaluate `whereJoined(.tags, .label, .like, ...)` on relation 'tagged_items': on the joined dataset 'tags', `.like` and `.ilike` filters need `supports.like`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.TaggedItemSchema, fakes.JoinNoLikeGateway);

export fn entry() void {
    var gw = fakes.JoinNoLikeGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.join(.tags).whereJoined(.tags, .label, .like, "x%");
}
