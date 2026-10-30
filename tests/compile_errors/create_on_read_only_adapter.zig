// expect: zom: adapter 'readonly' is not .writable, so `create` is not available on items (its dataset has no `insert`)
const std = @import("std");
const zom = @import("zom");

const ReadOnlyGateway = struct {
    pub const adapter_name = "readonly";
    pub const Config = struct {};

    pub fn init(_: std.mem.Allocator, _: Config) ReadOnlyGateway {
        return .{};
    }
    pub fn deinit(_: *ReadOnlyGateway) void {}

    pub fn Dataset(comptime S: type) type {
        return struct {
            pub fn read(_: *@This(), _: zom.Query(S.Tuple), a: std.mem.Allocator) ![]S.Tuple {
                return a.alloc(S.Tuple, 0);
            }
            pub fn count(_: *@This(), _: zom.Query(S.Tuple)) !usize {
                return 0;
            }
        };
    }

    pub fn dataset(_: *ReadOnlyGateway, comptime S: type) !*Dataset(S) {
        const static = struct {
            var instance: Dataset(S) = .{};
        };
        return &static.instance;
    }
};

const Item = struct { id: u32 };
const Items = zom.Relation(zom.Schema(Item, "items", .id), ReadOnlyGateway);

export fn entry() void {
    var gw = ReadOnlyGateway.init(std.heap.page_allocator, .{});
    const items = Items.init(&gw) catch return;
    _ = items.create(.{ .id = 1 }).commit() catch return;
}
