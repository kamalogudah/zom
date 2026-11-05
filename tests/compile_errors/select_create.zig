// expect: zom: `create` needs whole tuples, but relation 'users' is projected by `select`; call it on the relation before `select`
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32, name: []const u8, email: []const u8, age: u8 };
const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.select(.{.id}).create(.{ .id = 1, .name = "a", .email = "a@b", .age = 1 });
}
