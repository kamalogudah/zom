// expect: zom: container.transaction names unknown gateway 'defualt' (gateways: 'default', 'files')
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway, .files = fakes.ReadOnlyGateway },
    .relations = .{ .items = .{ fakes.ItemSchema, .files } },
});

fn f(_: void, _: App.Relations) !void {}

export fn entry() void {
    var app: App = undefined;
    app.transaction(.defualt, {}, f) catch {};
}
