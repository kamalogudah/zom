// expect: zom: condition has 33 nodes (filters plus any/all/not groups), more than max_nodes (32)
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32 };
const Q = zom.Query(User);

export fn entry() void {
    const q: Q = .{};
    // 32 NOTs around one filter.
    const n = zom.not;
    _ = q.whereNot(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(n(.{ .id, .eq, 1 }))))))))))))))))))))))))))))))));
}
