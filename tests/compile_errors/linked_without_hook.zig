// expect: zom: adapter 'memory' has no linked changesets for relation 'users' (its dataset has no `LinkedChangeset`)
const zom = @import("zom");

const User = struct { id: u32 = 0, name: []const u8 = "" };
const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

export fn entry() void {
    var gateway = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const users = Users.init(&gateway) catch return;
    _ = users.linked();
}
