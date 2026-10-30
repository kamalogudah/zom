// expect: zom: gateway 'adapter_missing_decls.FakeGateway' does not satisfy the adapter contract:
// expect: - missing `pub const adapter_name`
// expect: - missing `pub fn deinit`
const std = @import("std");
const zom = @import("zom");

const FakeGateway = struct {
    pub const Config = struct {};

    pub fn init(_: std.mem.Allocator, _: Config) FakeGateway {
        return .{};
    }

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

    pub fn dataset(_: *FakeGateway, comptime S: type) !*Dataset(S) {
        return error.Unused;
    }
};

comptime {
    _ = zom.Adapter(FakeGateway);
}
