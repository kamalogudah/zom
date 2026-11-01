// expect: zom: reorder has 5 keys, more than max_orders (4)
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32, age: u8 };
const Q = zom.Query(User);

export fn entry() void {
    const q: Q = .{};
    _ = q.reorder(.{ .{ .id, .asc }, .{ .age, .asc }, .{ .id, .desc }, .{ .age, .desc }, .{ .id, .asc } });
}
