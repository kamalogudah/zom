// expect: zom: gateway 'container_invalid_gateway.NotAGateway' does not satisfy the adapter contract:
// expect: - missing `pub const adapter_name`
// expect: - missing `pub fn dataset`
const std = @import("std");
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

const NotAGateway = struct {
    pub const Config = struct {};
    pub fn init(_: std.mem.Allocator, _: Config) NotAGateway {
        return .{};
    }
    pub fn deinit(_: *NotAGateway) void {}
};

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway, .broken = NotAGateway },
    .relations = .{ .items = .{ fakes.ItemSchema, .default } },
});

comptime {
    _ = App;
}
