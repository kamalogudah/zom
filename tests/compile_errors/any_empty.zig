// expect: zom: zom.any needs at least one condition
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32 };
const Q = zom.Query(User);

export fn entry() void {
    const q: Q = .{};
    _ = q.whereAny(.{});
}
