// expect: zom: condition has 17 filters, more than max_filters (16)
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32, age: u8 };
const Q = zom.Query(User);

export fn entry() void {
    const q: Q = .{};
    _ = q.whereAny(.{
        .{ .id, .eq, 1 },  .{ .id, .eq, 2 },  .{ .id, .eq, 3 },  .{ .id, .eq, 4 },
        .{ .id, .eq, 5 },  .{ .id, .eq, 6 },  .{ .id, .eq, 7 },  .{ .id, .eq, 8 },
        .{ .id, .eq, 9 },  .{ .id, .eq, 10 }, .{ .id, .eq, 11 }, .{ .id, .eq, 12 },
        .{ .id, .eq, 13 }, .{ .id, .eq, 14 }, .{ .id, .eq, 15 }, .{ .id, .eq, 16 },
        .{ .id, .eq, 17 },
    });
}
