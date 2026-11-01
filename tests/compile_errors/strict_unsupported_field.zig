// expect: zom: adapter 'limited' cannot evaluate `where(.name, .eq, ...)` on relation 'items': its dataset's `filterable` rejects `.eq` on 'name'; call `allowFallback()`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.LimitedGateway);

export fn entry() void {
    var gw = fakes.LimitedGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.where(.name, .eq, "x");
}
