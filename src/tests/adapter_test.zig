const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;

const Item = struct { id: u32, name: []const u8 };
const Items = zom.Schema(Item, "items", .id, .{});

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

    pub fn transaction(self: *Self, ctx: anytype, comptime f: anytype) !void {
        return f(ctx, self);
    }
};

fn expectCaps(comptime G: type, comptime want: zom.Capabilities) !void {
    try testing.expectEqual(want, comptime zom.Adapter(G).capabilities(Items));
}

test "memory gateway has every capability" {
    const A = zom.Adapter(zom.memory.Gateway);
    try testing.expectEqualStrings("memory", A.name);
    try expectCaps(zom.memory.Gateway, .{
        .writable = true,
        .batch_insert = true,
        .updatable = true,
        .deletable = true,
        .transaction = true,
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

fn SupportingDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        pub const supports: zom.Supports = .{ .in = true, .offset = false };

        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

test "memory supports every query feature" {
    try testing.expectEqual(zom.Supports.all, comptime zom.Adapter(zom.memory.Gateway).supports(Items));
}

test "a dataset without supports gets the defaults" {
    const s = comptime zom.Adapter(FakeGateway(ReadOnlyDataset)).supports(Items);
    try testing.expectEqual(zom.Supports{}, s);
    try testing.expect(!s.@"or" and !s.in and !s.like and !s.projection and !s.join);
    try testing.expect(s.order_on and s.offset);
}

test "a declared supports is returned as is" {
    try testing.expectEqual(
        zom.Supports{ .in = true, .offset = false },
        comptime zom.Adapter(FakeGateway(SupportingDataset)).supports(Items),
    );
}

test "the shared adapter errors merge into other error sets" {
    const E = zom.adapter.Error || error{Unrelated};
    const err: E = error.NotFound;
    try testing.expectEqual(error.NotFound, err);
    // Error names are global, so an adapter's own `error.ReadOnly` is the same one.
    try testing.expect(@as(anyerror, error.ReadOnly) == @as(anyerror, zom.adapter.Error.ReadOnly));
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
    try testing.expectEqual(null, try items.byPk(1).one(testing.allocator));

    // Chained queries compile and run too; only create/update/delete are
    // compile errors (tests/compile_errors/read_only_*.zig).
    const rows = try items.where(.name, .eq, "x").order(.id, .desc).limit(5).offset(1).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(0, rows.len);
    const mapped = try items.mapTo(struct { id: u32 }, testing.allocator);
    defer testing.allocator.free(mapped);
    try testing.expectEqual(0, mapped.len);
}

test "readOnly is true only without every write capability" {
    try testing.expect(zom.Adapter(FakeGateway(ReadOnlyDataset)).readOnly(Items));
    try testing.expect(!zom.Adapter(FakeGateway(AppendOnlyDataset)).readOnly(Items));
    try testing.expect(!zom.Adapter(zom.memory.Gateway).readOnly(Items));
}

/// What a recording dataset saw. One per dataset type, reset by each test.
const Calls = struct {
    insert: usize = 0,
    insert_many: usize = 0,
    ids: [8]u32 = undefined,
    stored: usize = 0,
    /// `insert` fails on this id, to show what the fallback loop leaves.
    fail_on: ?u32 = null,

    fn record(self: *Calls, id: u32) !void {
        if (self.fail_on == id) return error.DuplicatePrimaryKey;
        self.ids[self.stored] = id;
        self.stored += 1;
    }
};

/// `insert` only, so `createMany` has to loop.
fn InsertOnlyDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        calls: Calls = .{},

        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(self: *@This(), _: Q) !usize {
            return self.calls.stored;
        }
        pub fn insert(self: *@This(), t: T) !T {
            self.calls.insert += 1;
            try self.calls.record(t.id);
            return t;
        }
    };
}

/// Both `insert` and `insertMany`: `createMany` must pick `insertMany`.
fn BatchDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        calls: Calls = .{},

        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(self: *@This(), _: Q) !usize {
            return self.calls.stored;
        }
        pub fn insert(self: *@This(), t: T) !T {
            self.calls.insert += 1;
            try self.calls.record(t.id);
            return t;
        }
        pub fn insertMany(self: *@This(), ts: []const T) !usize {
            self.calls.insert_many += 1;
            for (ts) |t| try self.calls.record(t.id);
            return ts.len;
        }
    };
}

const batch = [_]Item{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" }, .{ .id = 3, .name = "c" } };

test "createMany falls back to a loop over insert without insertMany" {
    const G = FakeGateway(InsertOnlyDataset);
    try testing.expect(comptime !zom.Adapter(G).has(Items, .batch_insert));
    var gw = G.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try zom.Relation(Items, G).init(&gw);
    items.dataset.calls = .{};

    try testing.expectEqual(3, try items.createMany(&batch).commit());
    try testing.expectEqual(3, items.dataset.calls.insert);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, items.dataset.calls.ids[0..3]);

    // An empty batch never reaches the dataset.
    try testing.expectEqual(0, try items.createMany(&.{}).commit());
    try testing.expectEqual(3, items.dataset.calls.insert);
}

test "the fallback loop stops at the first error and keeps the rows before it" {
    const G = FakeGateway(InsertOnlyDataset);
    var gw = G.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try zom.Relation(Items, G).init(&gw);
    items.dataset.calls = .{ .fail_on = 2 };

    try testing.expectError(error.DuplicatePrimaryKey, items.createMany(&batch).commit());
    // Row 1 is stored, row 2 failed, row 3 was never tried.
    try testing.expectEqual(2, items.dataset.calls.insert);
    try testing.expectEqualSlices(u32, &.{1}, items.dataset.calls.ids[0..items.dataset.calls.stored]);
}

test "createMany uses insertMany when the dataset has it" {
    const G = FakeGateway(BatchDataset);
    var gw = G.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try zom.Relation(Items, G).init(&gw);
    items.dataset.calls = .{};

    try testing.expectEqual(3, try items.createMany(&batch).commit());
    try testing.expectEqual(1, items.dataset.calls.insert_many);
    try testing.expectEqual(0, items.dataset.calls.insert);
}

fn FilterableDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        pub const supports: zom.Supports = .{ .in = true, .order_on = false };

        pub fn filterable(comptime field: []const u8, comptime op: zom.Op) bool {
            return std.mem.eql(u8, field, "id") or op == .eq;
        }
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

/// Orders by `name` only, not by its primary key (like TigerBeetle, which
/// orders by `timestamp`).
fn OrderableDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        pub fn orderable(comptime field: []const u8) bool {
            return std.mem.eql(u8, field, "name");
        }
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]T {
            return a.alloc(T, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

test "filterGap and orderGap combine supports with filterable" {
    const A = zom.Adapter(FakeGateway(FilterableDataset));
    comptime {
        std.debug.assert(A.filterGap(Items, "id", .lt) == null);
        std.debug.assert(A.filterGap(Items, "id", .in) == null);
        std.debug.assert(A.filterGap(Items, "name", .eq) == null);
        std.debug.assert(A.filterGap(Items, "name", .between) != null);
        // `supports` is checked first: filterable is not asked about like.
        std.debug.assert(std.mem.indexOf(u8, A.filterGap(Items, "id", .like).?, "supports.like") != null);
        std.debug.assert(A.orderGap(Items, "id") == null);
        std.debug.assert(A.orderGap(Items, "name") != null);
    }
    // `orderable` narrows `order_on`, even on the primary key.
    const O = zom.Adapter(FakeGateway(OrderableDataset));
    comptime {
        std.debug.assert(O.orderGap(Items, "name") == null);
        std.debug.assert(std.mem.indexOf(u8, O.orderGap(Items, "id").?, "`orderable` rejects ordering by 'id'") != null);
    }
    // Memory supports everything, on every field.
    const M = zom.Adapter(zom.memory.Gateway);
    comptime std.debug.assert(M.filterGap(Items, "name", .ilike) == null and M.orderGap(Items, "name") == null);
}
