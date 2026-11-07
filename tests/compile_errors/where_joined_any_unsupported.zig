// expect: zom: adapter 'joinnolike' cannot evaluate `whereJoinedAny(.tags, ...)` on relation 'tagged_items': on the joined dataset 'tags', boolean groups (`whereJoinedAny`, `whereJoinedNot`) need `supports.or`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.TaggedItemSchema, fakes.JoinNoLikeGateway);

export fn entry() void {
    var gw = fakes.JoinNoLikeGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.join(.tags).whereJoinedAny(.tags, .{ .{ .label, .eq, "a" }, .{ .label, .eq, "b" } });
}
