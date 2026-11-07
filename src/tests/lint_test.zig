//! zom.lint run against the memory adapter, and against a read-only fake
//! that seeds through its factory.

const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const MemoryFactory = struct {
    pub fn create(allocator: Allocator) !zom.memory.Gateway {
        return zom.memory.Gateway.init(allocator, .{});
    }
    pub fn destroy(g: *zom.memory.Gateway) void {
        g.deinit();
    }
};

test "memory passes zom.lint" {
    try zom.lint.run(zom.memory.Gateway, MemoryFactory);
}

/// A gateway with one dataset over `memory.Store`, exposing only `read`
/// and `count`, like a CSV file opened read-only.
const ReadOnlyGateway = struct {
    pub const adapter_name = "lint-read-only";
    pub const Config = struct {};

    allocator: Allocator,
    users: ?*Dataset(zom.lint.Users) = null,

    pub fn init(allocator: Allocator, _: Config) ReadOnlyGateway {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReadOnlyGateway) void {
        if (self.users) |d| {
            d.store.deinit();
            self.allocator.destroy(d);
        }
    }

    pub fn Dataset(comptime S: type) type {
        return struct {
            const Self = @This();
            const Q = zom.Query(S.Tuple);
            store: zom.memory.Store(S),

            pub fn read(self: *Self, query: Q, allocator: Allocator) ![]S.Tuple {
                return self.store.read(query, allocator);
            }
            pub fn count(self: *Self, query: Q) !usize {
                return self.store.count(query);
            }
        };
    }

    pub fn dataset(self: *ReadOnlyGateway, comptime S: type) !*Dataset(S) {
        if (S != zom.lint.Users) @compileError("this fake only holds zom.lint.Users");
        if (self.users) |d| return d;
        const d = try self.allocator.create(Dataset(S));
        d.* = .{ .store = .init(self.allocator) };
        self.users = d;
        return d;
    }
};

const ReadOnlyFactory = struct {
    pub fn create(allocator: Allocator) !ReadOnlyGateway {
        return ReadOnlyGateway.init(allocator, .{});
    }
    pub fn destroy(g: *ReadOnlyGateway) void {
        g.deinit();
    }
    pub fn seed(g: *ReadOnlyGateway, comptime S: type, rows: []const S.Tuple) !void {
        const d = try g.dataset(S);
        _ = try d.store.loadMany(rows);
    }
};

test "a read-only adapter passes zom.lint, seeding through its factory" {
    try testing.expect(zom.Adapter(ReadOnlyGateway).readOnly(zom.lint.Users));
    try zom.lint.run(ReadOnlyGateway, ReadOnlyFactory);
}

test "capabilitySkips: the write checks a dataset has no capability for" {
    // Memory has every capability: nothing to skip.
    try testing.expectEqual(0, zom.lint.capabilitySkips(zom.memory.Gateway, zom.lint.Users).len);
    // Read only: every insert, update and delete check, each with its reason.
    const skips = comptime zom.lint.capabilitySkips(ReadOnlyGateway, zom.lint.Users);
    try testing.expectEqual(5, skips.len);
    try testing.expect(std.mem.startsWith(u8, skips[3].check, "update:"));
    try testing.expectEqualStrings("dataset has no `updatable` capability", skips[3].reason);
    try testing.expect(std.mem.startsWith(u8, skips[4].check, "delete:"));
    try testing.expectEqualStrings("dataset has no `deletable` capability", skips[4].reason);
}

/// A gateway whose dataset has `insert` but no `insertMany`, `update` or
/// `delete`, like an append-only log: lint seeds through `insert`, and
/// `createMany` falls back to the `insert` loop.
const AppendOnlyGateway = struct {
    pub const adapter_name = "lint-append-only";
    pub const Config = struct {};

    allocator: Allocator,
    users: ?*Dataset(zom.lint.Users) = null,

    pub fn init(allocator: Allocator, _: Config) AppendOnlyGateway {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AppendOnlyGateway) void {
        if (self.users) |d| {
            d.store.deinit();
            self.allocator.destroy(d);
        }
    }

    pub fn Dataset(comptime S: type) type {
        return struct {
            const Self = @This();
            const Q = zom.Query(S.Tuple);
            store: zom.memory.Store(S),

            pub fn read(self: *Self, query: Q, allocator: Allocator) ![]S.Tuple {
                return self.store.read(query, allocator);
            }
            pub fn count(self: *Self, query: Q) !usize {
                return self.store.count(query);
            }
            pub fn insert(self: *Self, row: S.Tuple) !S.Tuple {
                return self.store.insert(row);
            }
        };
    }

    pub fn dataset(self: *AppendOnlyGateway, comptime S: type) !*Dataset(S) {
        if (S != zom.lint.Users) @compileError("this fake only holds zom.lint.Users");
        if (self.users) |d| return d;
        const d = try self.allocator.create(Dataset(S));
        d.* = .{ .store = .init(self.allocator) };
        self.users = d;
        return d;
    }
};

const AppendOnlyFactory = struct {
    pub fn create(allocator: Allocator) !AppendOnlyGateway {
        return AppendOnlyGateway.init(allocator, .{});
    }
    pub fn destroy(g: *AppendOnlyGateway) void {
        g.deinit();
    }
};

test "an insert-only adapter passes zom.lint, with createMany's insert fallback" {
    try testing.expect(!zom.Adapter(AppendOnlyGateway).has(zom.lint.Users, .batch_insert));
    try zom.lint.run(AppendOnlyGateway, AppendOnlyFactory);
}
