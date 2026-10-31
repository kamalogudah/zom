// expect: zom: adapter 'noinsert' does not support `createMany` for relation 'items': `createMany` needs the `batch_insert` or `writable` capability (dataset has no `insertMany` or `insert`)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.NoInsertGateway);

export fn entry() void {
    var gw = fakes.NoInsertGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // `update` compiles: this adapter has it.
    _ = items.byPk(1).update().set(.name, "x").commit() catch return;
    _ = items.createMany(&.{.{ .id = 1 }});
}
