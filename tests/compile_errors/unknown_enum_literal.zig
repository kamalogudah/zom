// expect: zom: '.owner' is not a value of unknown_enum_literal.Role (attribute 'role')
const std = @import("std");
const zom = @import("zom");

const Role = enum { admin, member };
const User = struct { id: u32, age: u8, role: Role = .member, deleted_at: ?i64 = null };
const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.where(.role, .eq, .owner);
}
