// expect: zom: repository root 'posts' is not one of its relations (relations: 'users')
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway },
    .relations = .{ .users = .{ fakes.ItemSchema, .default }, .posts = .{ fakes.TagSchema, .default } },
});
const Repo = zom.Repository(App, .{ .root = .posts, .relations = .{.users} });

comptime {
    _ = Repo;
}
