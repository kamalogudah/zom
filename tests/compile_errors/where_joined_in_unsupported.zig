// expect: zom: adapter 'joinnolike' cannot evaluate `whereJoinedIn(.tags, .label, ...)` on relation 'tagged_items': on the joined dataset 'tags', `.in` and `.not_in` filters need `supports.in`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.TaggedItemSchema, fakes.JoinNoLikeGateway);

export fn entry() void {
    var gw = fakes.JoinNoLikeGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    const labels = [_][]const u8{ "a", "b" };
    _ = items.join(.tags).whereJoinedIn(.tags, .label, &labels);
}
