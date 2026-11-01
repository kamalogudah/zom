// expect: zom: .in on 'id' has 65 values, more than max_in (64)
const std = @import("std");
const zom = @import("zom");

const Role = enum { admin, member };
const User = struct { id: u32, name: []const u8, age: u8, role: Role = .member, deleted_at: ?i64 = null };
const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.where(.id, .in, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65 });
}
