// expect: zom: type mismatch on 'name': attribute is []const u8, got comptime_int
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32, name: []const u8 };
const Q = zom.Query(User);

export fn entry() void {
    const q: Q = .{};
    _ = q.whereNot(zom.any(.{ .{ .id, .eq, 1 }, .{ .name, .eq, 2 } }));
}
