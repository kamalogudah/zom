// expect: zom: adapter 'appendonly' does not support `delete` for relation 'items': `delete` needs the `deletable` capability (dataset has no `delete`)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.AppendOnlyGateway);

export fn entry() void {
    var gw = fakes.AppendOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // `create` compiles: this adapter has `insert`.
    _ = items.create(.{ .id = 1 }).commit() catch return;
    _ = items.byPk(1).delete() catch return;
}
