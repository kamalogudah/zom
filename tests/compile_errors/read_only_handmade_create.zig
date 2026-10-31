// expect: zom: adapter 'readonly' is read-only for relation 'items': `create` needs the `writable` capability (dataset has no `insert`)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.ReadOnlyGateway);

export fn entry() void {
    var gw = fakes.ReadOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // Built by hand, skipping `Relation.create`: `commit` still checks.
    const cs: zom.changeset.Create(Items) = .{ .relation = items, .tuple = .{ .id = 1 } };
    _ = cs.commit() catch return;
}
