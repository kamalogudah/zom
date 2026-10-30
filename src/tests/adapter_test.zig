const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;

const Item = struct { id: u32, name: []const u8 };
const Items = zom.Schema(Item, "items", .id);

/// The required gateway declarations around a dataset type function. Zig
/// cannot declare something conditionally, so each capability mix below is
/// its own dataset.
fn FakeGateway(comptime DatasetFn: fn (comptime type) type) type {
    return struct {
        const Self = @This();

        pub const adapter_name = "fake";
        pub const Config = struct {};

        pub fn init(_: std.mem.Allocator, _: Config) Self {
            return .{};
        }
        pub fn deinit(_: *Self) void {}

        pub const Dataset = DatasetFn;

        pub fn dataset(_: *Self, comptime S: type) !*Dataset(S) {
            const static = struct {
                var instance: Dataset(S) = .{};
            };
            return &static.instance;
        }
    };
}

fn ReadOnlyDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(_: *const @This(), _: Q) !usize {
            return 0;
        }
    };
}

fn AppendOnlyDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
        pub fn insert(_: *@This(), t: T) !T {
            return t;
        }
        pub fn insertMany(_: *@This(), ts: []const T) !usize {
            return ts.len;
        }
    };
}

fn MutableDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
        pub fn update(_: *@This(), _: Q, _: []const Q.Change) !usize {
            return 0;
        }
        pub fn delete(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

const TransactionalGateway = struct {
    const Self = @This();

    pub const adapter_name: []const u8 = "tx";
    pub const Config = struct { path: []const u8 = "" };

    pub fn init(_: std.mem.Allocator, _: Config) !Self {
        return .{};
    }
    pub fn deinit(_: *Self) void {}

    pub const Dataset = ReadOnlyDataset;

    pub fn dataset(_: *Self, comptime S: type) !*Dataset(S) {
        const static = struct {
            var instance: Dataset(S) = .{};
        };
        return &static.instance;
    }

    pub fn transaction(_: *Self, ctx: anytype, comptime f: anytype) !void {
        return f(ctx);
    }
};

fn expectCaps(comptime G: type, comptime want: zom.Capabilities) !void {
    try testing.expectEqual(want, comptime zom.Adapter(G).capabilities(Items));
}

test "memory gateway has every capability except transaction" {
    const A = zom.Adapter(zom.memory.Gateway);
    try testing.expectEqualStrings("memory", A.name);
    try expectCaps(zom.memory.Gateway, .{
        .writable = true,
        .batch_insert = false,
        .updatable = true,
        .deletable = true,
        .transaction = false,
    });
}

test "capabilities come from the optional declarations" {
    try expectCaps(FakeGateway(ReadOnlyDataset), .{});
    try expectCaps(FakeGateway(AppendOnlyDataset), .{ .writable = true, .batch_insert = true });
    try expectCaps(FakeGateway(MutableDataset), .{ .updatable = true, .deletable = true });
    try expectCaps(TransactionalGateway, .{ .transaction = true });

    const A = zom.Adapter(FakeGateway(AppendOnlyDataset));
    try testing.expect(comptime A.has(Items, .batch_insert));
    try testing.expect(comptime !A.has(Items, .deletable));
    try testing.expectEqualStrings("tx", zom.Adapter(TransactionalGateway).name);
}

test "a read-only adapter still reads through a relation" {
    const G = FakeGateway(ReadOnlyDataset);
    const Rel = zom.Relation(Items, G);
    try testing.expect(Rel.Adapter == zom.Adapter(G));

    var gw = G.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try Rel.init(&gw);
    try testing.expectEqual(0, try items.count());
    try testing.expectEqual(null, try items.first(testing.allocator));
}
