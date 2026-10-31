// expect: zom: container relation 'items' must be `.{ Schema, .gateway_name }`: the second element must be an enum literal naming a gateway
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway },
    .relations = .{ .items = .{ fakes.ItemSchema, "default" } },
});

comptime {
    _ = App;
}
