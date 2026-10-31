// expect: zom: adapter 'readonly' is read-only for relation 'items': `update` needs the `updatable` capability (dataset has no `update`)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.ReadOnlyGateway);

export fn entry() void {
    var gw = fakes.ReadOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    // Built by hand, skipping `Relation.update`: `commit` still checks.
    const cs: zom.changeset.Update(Items) = .{ .relation = items };
    _ = cs.set(.name, "x").commit() catch return;
}
