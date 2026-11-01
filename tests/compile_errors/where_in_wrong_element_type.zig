// expect: zom: type mismatch on 'id': attribute is u32, got []const u8
const std = @import("std");
const zom = @import("zom");

const Role = enum { admin, member };
const User = struct { id: u32, name: []const u8, age: u8, role: Role = .member, deleted_at: ?i64 = null };
const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    const names = [_][]const u8{"ada"};
    _ = users.whereIn(.id, &names);
}
