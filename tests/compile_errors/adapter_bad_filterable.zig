// expect: zom: dataset
// expect: - `filterable` must be `fn (comptime field: []const u8, comptime op: zom.Op) bool`, found `fn ([]const u8) bool`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const Items = zom.Relation(fakes.ItemSchema, fakes.BadFilterableGateway);

export fn entry() void {
    var gw = fakes.BadFilterableGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.byPk(1);
}
