// expect: zom: adapter 'orderable' cannot evaluate `order(.id, ...)` on relation 'items': its dataset's `orderable` rejects ordering by 'id'; call `allowFallback()`
//! `orderable` narrows ordering even on the primary key.
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.OrderableGateway);

export fn entry() void {
    var gw = fakes.OrderableGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // Ordering by `name` is fine.
    _ = items.order(.name, .asc).order(.id, .asc);
}
