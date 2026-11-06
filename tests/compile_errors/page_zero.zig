// expect: zom: `page(0)` on relation 'users': pages and page sizes start at 1
const zom = @import("zom");

const User = struct { id: u32 };
const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(@import("std").heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.page(0).perPage(10);
}
