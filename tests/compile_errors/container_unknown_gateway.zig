// expect: zom: container relation 'users' names unknown gateway 'defualt' (gateways: 'default', 'archive')
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway, .archive = zom.memory.Gateway },
    .relations = .{ .users = .{ fakes.ItemSchema, .defualt } },
});

comptime {
    _ = App;
}
