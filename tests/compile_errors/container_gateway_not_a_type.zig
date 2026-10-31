// expect: zom: container gateway 'default' must be a gateway type, found a value of type `comptime_int`
const zom = @import("zom");

const App = zom.Container(.{ .gateways = .{ .default = 42 }, .relations = .{} });

comptime {
    _ = App;
}
