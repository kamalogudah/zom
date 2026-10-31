//! Fake gateways shared by the compile-error cases. This file has no
//! `// expect:` line, so it lives in a subdirectory the harness skips.

const std = @import("std");
const zom = @import("zom");

pub const Item = struct { id: u32, name: []const u8 = "" };
pub const ItemSchema = zom.Schema(Item, "items", .id);

/// Only `read` and `count`: the read-only adapter of plan.md section 3.1.
pub const ReadOnlyGateway = Gateway("readonly", ReadOnlyDataset);
/// `read`, `count` and `insert`, but no `update` or `delete`.
pub const AppendOnlyGateway = Gateway("appendonly", AppendOnlyDataset);
/// `read`, `count`, `update` and `delete`, but no `insert` or `insertMany`.
pub const NoInsertGateway = Gateway("noinsert", NoInsertDataset);

fn Gateway(comptime name: []const u8, comptime DatasetFn: fn (comptime type) type) type {
    return struct {
        const Self = @This();

        pub const adapter_name = name;
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
    const Q = zom.Query(S.Tuple);
    return struct {
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

fn AppendOnlyDataset(comptime S: type) type {
    const Q = zom.Query(S.Tuple);
    return struct {
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
        pub fn insert(_: *@This(), t: S.Tuple) !S.Tuple {
            return t;
        }
    };
}

fn NoInsertDataset(comptime S: type) type {
    const Q = zom.Query(S.Tuple);
    return struct {
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
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
