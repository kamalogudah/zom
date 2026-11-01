// expect: zom: adapter 'limited' cannot evaluate `order(.name, ...)` on relation 'items': `supports.order_on` is false, so it only orders by the primary key 'id'; call `allowFallback()`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.LimitedGateway);

export fn entry() void {
    var gw = fakes.LimitedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // Ordering by the key is fine.
    _ = items.order(.id, .desc).order(.name, .asc);
}
