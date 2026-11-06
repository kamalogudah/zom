// expect: zom: repository relation 'postz' is not in the container (relations: 'users', 'posts')
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway },
    .relations = .{ .users = .{ fakes.ItemSchema, .default }, .posts = .{ fakes.TagSchema, .default } },
});
const Repo = zom.Repository(App, .{ .root = .users, .relations = .{ .users, .postz } });

comptime {
    _ = Repo;
}
