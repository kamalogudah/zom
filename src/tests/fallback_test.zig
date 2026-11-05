//! `.fallback` relations over a dataset that only filters with `eq`: the
//! rest of the query runs in memory, and paging runs after it.

const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const UserTuple = fixtures.UserTuple;
const UserSchema = zom.Schema(UserTuple, "users", .id, .{});
const Q = zom.Query(UserTuple);

/// A memory store behind a dataset that supports `supports`, and filters
/// with `eq` only. It fails the test if zom hands it anything else, and
/// keeps the last query it was given.
fn EqOnlyDataset(comptime S: type, comptime s: zom.Supports) type {
    const T = S.Tuple;
    const DQ = zom.Query(T);
    return struct {
        const Self = @This();
        pub const supports: zom.Supports = s;

        pub fn filterable(comptime field: []const u8, comptime op: zom.Op) bool {
            _ = field;
            return op == .eq;
        }

        store: zom.memory.Store(S),
        reads: usize = 0,
        last: DQ = .{},

        fn expectSupported(query: DQ) !void {
            if (!s.@"or") try testing.expect(query.isConjunction());
            for (query.filters[0..query.filter_count]) |f| try testing.expectEqual(zom.Op.eq, f.op);
            if (!s.order_on) {
                for (query.orderSlice()) |o| try testing.expectEqual(S.primary_key, o.field);
            }
            if (!s.offset) try testing.expectEqual(0, query.offset);
        }

        pub fn read(self: *Self, query: DQ, a: std.mem.Allocator) ![]T {
            try expectSupported(query);
            self.reads += 1;
            self.last = query;
            return self.store.read(query, a);
        }
        pub fn count(self: *Self, query: DQ) !usize {
            try expectSupported(query);
            self.last = query;
            return self.store.count(query);
        }
        pub fn insert(self: *Self, t: T) !T {
            return self.store.insert(t);
        }
        pub fn update(self: *Self, query: DQ, changes: []const DQ.Change) !usize {
            try expectSupported(query);
            return self.store.update(query, changes);
        }
        pub fn delete(self: *Self, query: DQ) !usize {
            try expectSupported(query);
            return self.store.delete(query);
        }
    };
}

fn EqOnlyGateway(comptime s: zom.Supports) type {
    return struct {
        const Self = @This();
        pub const adapter_name = "eq_only";
        pub const Config = struct {};

        users: EqOnlyDataset(UserSchema, s),

        pub fn init(a: std.mem.Allocator, _: Config) Self {
            return .{ .users = .{ .store = .init(a) } };
        }
        pub fn deinit(self: *Self) void {
            self.users.store.deinit();
        }
        pub fn Dataset(comptime S: type) type {
            return EqOnlyDataset(S, s);
        }
        pub fn dataset(self: *Self, comptime S: type) !*Dataset(S) {
            if (S != UserSchema) @compileError("eq_only only stores users");
            return &self.users;
        }
    };
}

const rows = [_]UserTuple{
    .{ .id = 1, .name = "Achieng", .email = "a@example.com", .age = 31, .role = .admin },
    .{ .id = 2, .name = "Otieno", .email = "o@example.com", .age = 24 },
    .{ .id = 3, .name = "Wanjiru", .email = "w@example.com", .age = 42 },
    .{ .id = 4, .name = "Kamau", .email = "k@example.com", .age = 19 },
    .{ .id = 5, .name = "Njeri", .email = "n@example.com", .age = 37 },
    .{ .id = 6, .name = "Odhiambo", .email = "d@example.com", .age = 28, .role = .admin },
};

var scans: usize = 0;
var last_scan: ?zom.Scan = null;

fn recordScan(scan: zom.Scan) void {
    scans += 1;
    last_scan = scan;
}

fn Fixture(comptime s: zom.Supports) type {
    return struct {
        const G = EqOnlyGateway(s);
        const Users = zom.Relation(UserSchema, G);

        gw: G,

        fn init(self: *@This()) !Users {
            self.gw = G.init(testing.allocator, .{});
            errdefer self.gw.deinit();
            const users = try Users.init(&self.gw);
            for (rows) |r| _ = try users.create(r).commit();
            return users.onScan(recordScan);
        }

        fn deinit(self: *@This()) void {
            self.gw.deinit();
        }
    };
}

fn expectIds(want: []const u32, got: []const UserTuple) !void {
    var ids: [rows.len]u32 = undefined;
    for (got, 0..) |r, i| ids[i] = r.id;
    try testing.expectEqualSlices(u32, want, ids[0..got.len]);
}

test "lt filters run in memory, and limit and offset after them" {
    var f: Fixture(.{}) = undefined;
    const users = try f.init();
    defer f.deinit();

    // Members under 40, by id: 2, 4, 5. Skip one, take two.
    const page = users.allowFallback()
        .where(.role, .eq, .member)
        .where(.age, .lt, 40)
        .order(.id, .asc)
        .offset(1)
        .limit(2);
    const before = scans;
    const got = try page.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try expectIds(&.{ 4, 5 }, got);

    // The dataset saw only the eq filter and the order, with no paging:
    // paging it would have cut rows before the lt filter ran.
    const pushed = f.gw.users.last;
    try testing.expectEqual(1, pushed.filter_count);
    try testing.expectEqual(.role, pushed.filters[0].field);
    try testing.expectEqual(1, pushed.orderSlice().len);
    try testing.expectEqual(null, pushed.limit);
    try testing.expectEqual(0, pushed.offset);

    // One scan: the four members fetched, two returned.
    try testing.expectEqual(before + 1, scans);
    try testing.expectEqualStrings("eq_only", last_scan.?.adapter);
    try testing.expectEqualStrings("users", last_scan.?.relation);
    try testing.expectEqual(4, last_scan.?.rows_fetched);
    try testing.expectEqual(2, last_scan.?.rows_returned);

    // count follows the same rule.
    try testing.expectEqual(2, try page.count(testing.allocator));
    try testing.expectEqual(3, try page.limit(10).offset(0).count(testing.allocator));
    // An offset past the end is an empty page, not an error.
    try testing.expectEqual(0, try page.offset(5).count(testing.allocator));
}

test "fallback reads give what the memory adapter gives for the same query" {
    var f: Fixture(.{}) = undefined;
    const users = try f.init();
    defer f.deinit();

    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const memory = try zom.Relation(UserSchema, zom.memory.Gateway).init(&gw);
    for (rows) |r| _ = try memory.create(r).commit();

    const pages = [_][2]usize{ .{ 0, 100 }, .{ 0, 2 }, .{ 1, 2 }, .{ 3, 10 }, .{ 7, 1 } };
    for (pages) |paging| {
        const want = try memory.where(.age, .gte, 24).order(.age, .desc).offset(paging[0]).limit(paging[1]).toSlice(testing.allocator);
        defer testing.allocator.free(want);
        const got = try users.allowFallback().where(.age, .gte, 24).order(.age, .desc).offset(paging[0]).limit(paging[1]).toSlice(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqualDeep(want, got);
    }
}

test "a query the dataset supports is pushed down whole, with no scan" {
    var f: Fixture(.{}) = undefined;
    const users = try f.init();
    defer f.deinit();

    const before = scans;
    const admins = users.allowFallback().where(.role, .eq, .admin).order(.id, .desc).offset(1).limit(1);
    const got = try admins.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try expectIds(&.{1}, got);
    try testing.expectEqual(1, f.gw.users.last.limit);
    try testing.expectEqual(1, f.gw.users.last.offset);
    try testing.expectEqual(1, try admins.count(testing.allocator));
    try testing.expectEqual(before, scans);
}

test "the strict relation over the same adapter runs the supported part unchanged" {
    var f: Fixture(.{}) = undefined;
    const users = try f.init();
    defer f.deinit();

    try testing.expect(@TypeOf(users).mode == .strict);
    try testing.expect(@TypeOf(users.allowFallback()).mode == .fallback);
    // Strict `count` takes no allocator.
    try testing.expectEqual(4, try users.where(.role, .eq, .member).count());
}

test "an order the dataset can't run is sorted in memory, before paging" {
    var f: Fixture(.{ .order_on = false }) = undefined;
    const users = try f.init();
    defer f.deinit();

    const got = try users.allowFallback().order(.age, .desc).limit(2).toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try expectIds(&.{ 3, 5 }, got);
    try testing.expectEqual(0, f.gw.users.last.orderSlice().len);
    try testing.expectEqual(null, f.gw.users.last.limit);

    // Ordering by the key is still pushed down, and ties on age keep it.
    const by_role = try users.allowFallback().reorder(.{ .{ .role, .asc }, .{ .id, .desc } }).toSlice(testing.allocator);
    defer testing.allocator.free(by_role);
    try expectIds(&.{ 6, 1, 5, 4, 3, 2 }, by_role);
}

test "without offset support, the dataset reads offset + limit rows and zom skips" {
    var f: Fixture(.{ .offset = false }) = undefined;
    const users = try f.init();
    defer f.deinit();

    const before = scans;
    const got = try users.allowFallback().where(.role, .eq, .member).order(.id, .asc).offset(1).limit(2).toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try expectIds(&.{ 3, 4 }, got);
    try testing.expectEqual(3, f.gw.users.last.limit);
    try testing.expectEqual(0, f.gw.users.last.offset);
    try testing.expectEqual(before + 1, scans);
    try testing.expectEqual(3, last_scan.?.rows_fetched);
    try testing.expectEqual(2, last_scan.?.rows_returned);
}

test "boolean groups run in memory without `or` support" {
    var f: Fixture(.{}) = undefined;
    const users = try f.init();
    defer f.deinit();

    const rel = users.allowFallback()
        .where(.role, .eq, .member)
        .whereAny(.{ .{ .age, .lt, 20 }, .{ .age, .gt, 40 } })
        .order(.id, .asc);
    const got = try rel.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try expectIds(&.{ 3, 4 }, got);
    try testing.expect(f.gw.users.last.isConjunction());
    try testing.expectEqual(1, f.gw.users.last.filter_count);

    // A group of eq filters still needs `or`, so it runs in memory too.
    const not_two = try users.allowFallback().whereNot(.{ .id, .eq, 2 }).where(.role, .eq, .member).toSlice(testing.allocator);
    defer testing.allocator.free(not_two);
    try expectIds(&.{ 3, 4, 5 }, not_two);
}

test "with `or` support, a group of supported filters is pushed down" {
    var f: Fixture(.{ .@"or" = true }) = undefined;
    const users = try f.init();
    defer f.deinit();

    const before = scans;
    const got = try users.allowFallback()
        .whereAny(.{ .{ .id, .eq, 2 }, zom.not(.{ .role, .eq, .member }) })
        .where(.age, .lt, 30)
        .order(.id, .asc)
        .toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try expectIds(&.{ 2, 6 }, got);
    // The group went to the dataset; the lt filter stayed in memory.
    try testing.expectEqual(4, f.gw.users.last.node_count); // any, eq, not, eq
    try testing.expectEqual(2, f.gw.users.last.filter_count);
    try testing.expectEqual(before + 1, scans);
}

test "select on a fallback relation maps the filtered rows down" {
    var f: Fixture(.{}) = undefined;
    const users = try f.init();
    defer f.deinit();

    const got = try users.allowFallback().where(.age, .gt, 35).order(.id, .asc).select(.{.name}).toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(2, got.len);
    try testing.expectEqualStrings("Wanjiru", got[0].name);
    try testing.expectEqualStrings("Njeri", got[1].name);

    const one = (try users.allowFallback().where(.age, .lt, 20).select(.{ .id, .name }).one(testing.allocator)).?;
    try testing.expectEqual(4, one.id);
}

test "update and delete never run in memory" {
    var f: Fixture(.{}) = undefined;
    const users = (try f.init()).allowFallback();
    defer f.deinit();

    try testing.expectError(error.UnsupportedFilter, users.where(.age, .lt, 20).delete());
    try testing.expectError(error.UnsupportedFilter, users.where(.age, .lt, 20).update().set(.age, 20).commit());
    try testing.expectEqual(6, try users.count(testing.allocator));

    // Filters the dataset evaluates are fine.
    try testing.expectEqual(1, try users.byPk(4).update().set(.age, 20).commit());
    try testing.expectEqual(1, try users.byPk(4).delete());
    try testing.expectEqual(5, try users.count(testing.allocator));
}

test "a container's on_scan hook reaches every relation" {
    const App = zom.Container(.{
        .gateways = .{ .default = EqOnlyGateway(.{}) },
        .relations = .{ .users = .{ UserSchema, .default } },
        .on_scan = recordScan,
    });
    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();
    const users = app.relations.users;
    for (rows) |r| _ = try users.create(r).commit();

    const before = scans;
    const young = try users.allowFallback().where(.age, .lt, 25).toSlice(testing.allocator);
    defer testing.allocator.free(young);
    try testing.expectEqual(2, young.len);
    try testing.expectEqual(before + 1, scans);
    try testing.expectEqual(6, last_scan.?.rows_fetched);
    try testing.expectEqual(2, last_scan.?.rows_returned);
}
