// expect: zom: type mismatch on 'weight': attribute is u8, got []const u8
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.TaggedItemSchema, fakes.JoinNoLikeGateway);

export fn entry() void {
    var gw = fakes.JoinNoLikeGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    const heavy: []const u8 = "heavy";
    _ = items.join(.tags).whereJoined(.tags, .weight, .eq, heavy);
}
