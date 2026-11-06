// expect: zom: adapter 'readonly' is read-only for relation 'items': `create` needs the `writable` capability (dataset has no `insert`)
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const App = zom.Container(.{
    .gateways = .{ .default = fakes.ReadOnlyGateway },
    .relations = .{ .items = .{ fakes.ItemSchema, .default } },
});
const Repo = zom.Repository(App, .{ .root = .items, .relations = .{.items} });

export fn entry() void {
    var app: App = undefined;
    app.init(std.heap.page_allocator, .{}) catch return;
    const repo = Repo.init(&app);
    // Reads compile; the create shortcut inherits the relation's error.
    _ = repo.byPk(1);
    _ = repo.create(.{ .id = 1 });
}
