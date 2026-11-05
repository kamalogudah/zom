// expect: no field named 'email' in struct
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32, name: []const u8, email: []const u8, age: u8 };
const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    const rows = users.select(.{ .id, .name }).toSlice(std.heap.page_allocator) catch return;
    _ = rows[0].email;
}
