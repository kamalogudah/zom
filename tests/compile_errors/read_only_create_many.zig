// expect: zom: adapter 'readonly' is read-only for relation 'items': `createMany` needs the `batch_insert` or `writable` capability (dataset has no `insertMany` or `insert`)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.ReadOnlyGateway);

export fn entry() void {
    var gw = fakes.ReadOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // Fails at `createMany` itself, before a changeset exists.
    _ = items.createMany(&.{.{ .id = 1 }});
}
