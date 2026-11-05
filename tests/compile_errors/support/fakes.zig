//! Fake gateways shared by the compile-error cases. This file has no
//! `// expect:` line, so it lives in a subdirectory the harness skips.

const std = @import("std");
const zom = @import("zom");

pub const Item = struct { id: u32, name: []const u8 = "" };
pub const ItemSchema = zom.Schema(Item, "items", .id, .{});

/// Items with tags, for the join cases.
pub const Tag = struct { id: u32, item_id: u32, label: []const u8, weight: u8 = 0 };
pub const TaggedItemSchema = zom.Schema(Item, "tagged_items", .id, .{
    .associations = struct {
        pub const tags = zom.hasMany(TagSchema, .item_id);
    },
});
pub const TagSchema = zom.Schema(Tag, "tags", .id, .{});

/// Only `read` and `count`: the read-only adapter of plan.md section 3.1.
pub const ReadOnlyGateway = Gateway("readonly", ReadOnlyDataset);
/// `read`, `count` and `insert`, but no `update` or `delete`.
pub const AppendOnlyGateway = Gateway("appendonly", AppendOnlyDataset);
/// `read`, `count`, `update` and `delete`, but no `insert` or `insertMany`.
pub const NoInsertGateway = Gateway("noinsert", NoInsertDataset);
/// Reads, with limited query support: `in` but not `like` or `or`, no
/// `offset`, ordering by the key only, and filters on `id` only.
pub const LimitedGateway = Gateway("limited", LimitedDataset);
/// Reads, supporting joins but not `like`.
pub const JoinNoLikeGateway = Gateway("joinnolike", JoinNoLikeDataset);
/// Reads, supporting boolean groups but not `in`.
pub const OrOnlyGateway = Gateway("oronly", OrOnlyDataset);
/// `filterable` with the wrong signature.
pub const BadFilterableGateway = Gateway("badfilterable", BadFilterableDataset);
/// Caller-owned strings, with `insert` taking the allocator (like zom-pg).
pub const OwnedGateway = Gateway("owned", OwnedDataset(true));
/// Caller-owned strings, but `insert` takes no allocator: a contract error.
pub const OwnedNoAllocGateway = Gateway("ownednoalloc", OwnedDataset(false));

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

fn LimitedDataset(comptime S: type) type {
    const Q = zom.Query(S.Tuple);
    return struct {
        pub const supports: zom.Supports = .{ .in = true, .order_on = false, .offset = false };

        pub fn filterable(comptime field: []const u8, comptime op: zom.Op) bool {
            _ = op;
            return std.mem.eql(u8, field, "id");
        }
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

fn JoinNoLikeDataset(comptime S: type) type {
    const Q = zom.Query(S.Tuple);
    return struct {
        pub const supports: zom.Supports = .{ .join = true };

        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

fn BadFilterableDataset(comptime S: type) type {
    const Q = zom.Query(S.Tuple);
    return struct {
        pub fn filterable(field: []const u8) bool {
            return field.len > 0;
        }
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

fn OrOnlyDataset(comptime S: type) type {
    const Q = zom.Query(S.Tuple);
    return struct {
        pub const supports: zom.Supports = .{ .@"or" = true };

        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

fn OwnedDataset(comptime insert_takes_allocator: bool) fn (comptime type) type {
    return struct {
        fn D(comptime S: type) type {
            const Q = zom.Query(S.Tuple);
            return struct {
                pub const strings: zom.StringOwnership = .caller;
                pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
                    return a.alloc(S.Tuple, 0);
                }
                pub fn count(_: *@This(), _: Q) !usize {
                    return 0;
                }
                pub const insert = if (insert_takes_allocator) insertAlloc else insertPlain;
                fn insertAlloc(_: *@This(), t: S.Tuple, _: std.mem.Allocator) !S.Tuple {
                    return t;
                }
                fn insertPlain(_: *@This(), t: S.Tuple) !S.Tuple {
                    return t;
                }
            };
        }
    }.D;
}
