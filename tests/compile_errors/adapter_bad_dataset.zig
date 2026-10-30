// expect: zom: dataset 'adapter_bad_dataset.FakeGateway.Dataset(schema.Schema(adapter_bad_dataset.Item,"items"[0..5],.id))' of gateway 'adapter_bad_dataset.FakeGateway' does not satisfy the adapter contract:
// expect: - `read` must be `fn (*Self, zom.Query(Tuple), std.mem.Allocator) ![]Tuple`, found `fn (*adapter_bad_dataset.FakeGateway.Dataset(
// expect: - missing `pub fn count`
// expect: query.Query(adapter_bad_dataset.Item), mem.Allocator) !adapter_bad_dataset.Item`
// expect: - `delete` must be `fn (*Self, zom.Query(Tuple)) !usize`, found
const std = @import("std");
const zom = @import("zom");

const FakeGateway = struct {
    pub const adapter_name = "fake";
    pub const Config = struct {};

    pub fn init(_: std.mem.Allocator, _: Config) FakeGateway {
        return .{};
    }
    pub fn deinit(_: *FakeGateway) void {}

    pub fn Dataset(comptime S: type) type {
        return struct {
            // Returns one tuple, not a slice; count is missing; delete is not fallible.
            pub fn read(_: *@This(), _: zom.Query(S.Tuple), _: std.mem.Allocator) !S.Tuple {
                return error.Unused;
            }
            pub fn delete(_: *@This(), _: zom.Query(S.Tuple)) usize {
                return 0;
            }
        };
    }

    pub fn dataset(_: *FakeGateway, comptime S: type) !*Dataset(S) {
        return error.Unused;
    }
};

const Item = struct { id: u32 };

comptime {
    _ = zom.Adapter(FakeGateway).Dataset(zom.Schema(Item, "items", .id));
}
