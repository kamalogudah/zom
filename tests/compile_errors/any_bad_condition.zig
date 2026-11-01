// expect: zom: a condition is .{ field, op, value }, zom.any(...), zom.all(...) or zom.not(...)
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32 };
const Q = zom.Query(User);

export fn entry() void {
    const q: Q = .{};
    _ = q.whereAny(.{ .{ .id, .eq }, .{ .id, .eq, 2 } });
}
