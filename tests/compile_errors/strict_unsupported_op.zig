// expect: zom: adapter 'limited' cannot evaluate `where(.id, .like, ...)` on relation 'items': `.like` and `.ilike` filters need `supports.like`; call `allowFallback()` on the relation to evaluate it in memory instead
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Item = struct { id: []const u8, n: u32 = 0 };
const Items = zom.Relation(zom.Schema(Item, "items", .id), fakes.LimitedGateway);

export fn entry() void {
    var gw = fakes.LimitedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.where(.id, .like, "a%");
}
