// expect: zom: adapter 'limited' cannot evaluate `offset(...)` on relation 'items': `supports.offset` is false; call `allowFallback()`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.LimitedGateway);

export fn entry() void {
    var gw = fakes.LimitedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.limit(10).offset(20);
}
