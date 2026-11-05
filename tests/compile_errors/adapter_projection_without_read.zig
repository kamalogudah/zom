// expect: - `supports.projection` is true, but there is no `pub fn readProjected`
const std = @import("std");
const zom = @import("zom");

const Item = struct { id: u32, name: []const u8 };

const FakeGateway = struct {
    pub const adapter_name = "fake";
    pub const Config = struct {};

    pub fn init(_: std.mem.Allocator, _: Config) FakeGateway {
        return .{};
    }
    pub fn deinit(_: *FakeGateway) void {}

    pub fn Dataset(comptime S: type) type {
        const Q = zom.Query(S.Tuple);
        return struct {
            // Claims projection, but has no readProjected.
            pub const supports: zom.Supports = .{ .projection = true };
            pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
                return a.alloc(S.Tuple, 0);
            }
            pub fn count(_: *@This(), _: Q) !usize {
                return 0;
            }
        };
    }

    pub fn dataset(_: *FakeGateway, comptime S: type) !*Dataset(S) {
        return error.Unused;
    }
};

export fn entry() void {
    _ = zom.Adapter(FakeGateway).Dataset(zom.Schema(Item, "items", .id, .{}));
}
