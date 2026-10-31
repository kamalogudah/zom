// expect: zom: adapter 'readonly' is read-only for relation 'items': `delete` needs the `deletable` capability (dataset has no `delete`)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.ReadOnlyGateway);

export fn entry() void {
    var gw = fakes.ReadOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.byPk(1).delete() catch return;
}
