//! zom-csv = rom's `rom-csv`: a gateway over a directory of CSV files.
//!
//! This is the package skeleton. `Gateway` satisfies the adapter contract
//! with empty, read-only datasets so the build layout can be checked now; the
//! CSV reader and writer, and a `zom.memory.Store(S)` per dataset, come in
//! later tickets.

const std = @import("std");
const zom = @import("zom");

pub const Gateway = struct {
    pub const adapter_name = "csv";

    pub const Config = struct {
        /// The directory holding one `<dataset name>.csv` per schema.
        dir: []const u8 = ".",
    };

    config: Config,

    pub fn init(_: std.mem.Allocator, config: Config) Gateway {
        return .{ .config = config };
    }

    pub fn deinit(_: *Gateway) void {}

    pub fn Dataset(comptime S: type) type {
        return struct {
            const Q = zom.Query(S.Tuple);

            /// Stub: every dataset is empty.
            pub fn read(_: *@This(), _: Q, allocator: std.mem.Allocator) ![]S.Tuple {
                return allocator.alloc(S.Tuple, 0);
            }

            /// Stub: every dataset is empty.
            pub fn count(_: *@This(), _: Q) !usize {
                return 0;
            }
        };
    }

    /// Stub: the dataset holds no state yet, so one static instance per
    /// schema is enough. The real gateway will own its datasets.
    pub fn dataset(_: *Gateway, comptime S: type) !*Dataset(S) {
        const static = struct {
            var instance: Dataset(S) = .{};
        };
        return &static.instance;
    }
};

test "Gateway satisfies the zom adapter contract and reads through zom.Relation" {
    const User = struct { id: u32, name: []const u8 };
    const Users = zom.Schema(User, "users", .id);
    const A = zom.Adapter(Gateway);

    try std.testing.expectEqualStrings("csv", A.name);
    try std.testing.expect(A.readOnly(Users));

    var gw = Gateway.init(std.testing.allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(Users, Gateway).init(&gw);
    try std.testing.expectEqual(0, try users.count());
}
