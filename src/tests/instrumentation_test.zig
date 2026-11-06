const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");
const ins = zom.plugins.instrumentation;

const Item = struct { id: u32, name: []const u8 };

// -- a hook that records every call ------------------------------------------

const Phase = enum { before, after };

const Record = struct {
    phase: Phase,
    op: ins.Op,
    dataset: []const u8,
    adapter: []const u8,
    has_query: bool,
    rows: ?usize = null,
    err: ?[]const u8 = null,
    duration_ns: ?u64 = null,
};

var records: [32]Record = undefined;
var record_len: usize = 0;
/// The `id` of an `.id, .eq` filter in the last query a `before` hook saw.
var last_query_id: ?u32 = null;

const Recorder = struct {
    pub fn before(e: ins.Event) void {
        push(.{ .phase = .before, .op = e.op, .dataset = e.dataset, .adapter = e.adapter, .has_query = e.query != null });
        last_query_id = null;
        if (e.queryOf(Item)) |query| {
            for (query.filterSlice()) |f| {
                if (f.field == .id and f.op == .eq) last_query_id = @intCast(f.operand.one.int);
            }
        }
    }

    pub fn after(e: ins.Event, o: ins.Outcome) void {
        push(.{
            .phase = .after,
            .op = e.op,
            .dataset = e.dataset,
            .adapter = e.adapter,
            .has_query = e.query != null,
            .rows = o.rows,
            .err = o.err,
            .duration_ns = o.duration_ns,
        });
    }

    fn push(r: Record) void {
        records[record_len] = r;
        record_len += 1;
    }
};

/// A clock that moves 10ns on each read, so a call's duration is 10ns.
var ticks: i64 = 0;
fn advance(_: ?*anyopaque) i64 {
    ticks += 10;
    return ticks;
}

const ItemSchema = zom.Schema(Item, "items", .id, .{ .plugins = .{Recorder} });
const Items = zom.Relation(ItemSchema, zom.memory.Gateway);

fn items(gw: *zom.memory.Gateway) !Items {
    record_len = 0;
    ticks = 0;
    return (try Items.init(gw)).withPluginContext(.{ .clock = .{ .func = .{ .now = advance } } });
}

fn expectRecords(want: []const Record) !void {
    const got = records[0..record_len];
    if (want.len != got.len) {
        std.debug.print("want {d} records, got {d}:\n", .{ want.len, got.len });
        for (got) |r| std.debug.print("  {s} {s}\n", .{ @tagName(r.phase), @tagName(r.op) });
        return error.TestExpectedEqual;
    }
    for (want, got) |w, g| {
        try testing.expectEqual(w.phase, g.phase);
        try testing.expectEqual(w.op, g.op);
        try testing.expectEqualStrings(w.dataset, g.dataset);
        try testing.expectEqualStrings(w.adapter, g.adapter);
        try testing.expectEqual(w.has_query, g.has_query);
        try testing.expectEqual(w.rows, g.rows);
        try testing.expectEqual(w.duration_ns, g.duration_ns);
        if (w.err) |e| try testing.expectEqualStrings(e, g.err.?) else try testing.expectEqual(null, g.err);
    }
}

fn before(op: ins.Op, has_query: bool) Record {
    return .{ .phase = .before, .op = op, .dataset = "items", .adapter = "memory", .has_query = has_query };
}

fn after(op: ins.Op, has_query: bool, rows: ?usize, err: ?[]const u8) Record {
    return .{ .phase = .after, .op = op, .dataset = "items", .adapter = "memory", .has_query = has_query, .rows = rows, .err = err, .duration_ns = 10 };
}

// -- tests ---------------------------------------------------------------------

test "create + read + update: the exact sequence of events" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try items(&gw);

    _ = try rel.create(.{ .id = 1, .name = "a" }).commit();
    const rows = try rel.byPk(1).toSlice(testing.allocator);
    rel.free(testing.allocator, rows);
    _ = try rel.byPk(1).update().set(.name, "b").commit();

    try expectRecords(&.{
        before(.insert, false), after(.insert, false, 1, null),
        before(.read, true),    after(.read, true, 1, null),
        before(.update, true),  after(.update, true, 1, null),
    });
    // The hook sees the query the dataset gets.
    try testing.expectEqual(1, last_query_id);
}

test "errors are reported with @errorName, and still returned" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try items(&gw);

    _ = try rel.create(.{ .id = 1, .name = "a" }).commit();
    try testing.expectError(error.DuplicatePrimaryKey, rel.create(.{ .id = 1, .name = "again" }).commit());

    try expectRecords(&.{
        before(.insert, false), after(.insert, false, 1, null),
        before(.insert, false), after(.insert, false, null, "DuplicatePrimaryKey"),
    });
}

test "count, delete, createMany, one and a projected read" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try items(&gw);

    const batch = [_]Item{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" }, .{ .id = 3, .name = "c" } };
    try testing.expectEqual(3, try rel.createMany(&batch).commit());
    try testing.expectEqual(3, try rel.count());
    try testing.expectEqual(1, try rel.where(.id, .gt, 2).delete());
    const names = try rel.select(.{.name}).toSlice(testing.allocator);
    testing.allocator.free(names);
    _ = try rel.byPk(2).one(testing.allocator);

    try expectRecords(&.{
        before(.insert_many, false), after(.insert_many, false, 3, null),
        before(.count, true),        after(.count, true, 3, null),
        before(.delete, true),       after(.delete, true, 1, null),
        before(.read, true),         after(.read, true, 2, null),
        before(.read, true),         after(.read, true, 1, null),
    });
}

test "pagination is a count then a read" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try items(&gw);
    const batch = [_]Item{ .{ .id = 1, .name = "a" }, .{ .id = 2, .name = "b" }, .{ .id = 3, .name = "c" } };
    _ = try rel.createMany(&batch).commit();
    record_len = 0;

    const p = try rel.page(2).perPage(2).paginate(testing.allocator);
    defer p.free(testing.allocator);
    try expectRecords(&.{
        before(.count, true), after(.count, true, 3, null),
        before(.read, true),  after(.read, true, 1, null),
    });
}

test "without a clock, the duration is null" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    record_len = 0;
    const rel = try Items.init(&gw);
    _ = try rel.create(.{ .id = 1, .name = "a" }).commit();
    try testing.expectEqual(2, record_len);
    try testing.expectEqual(null, records[1].duration_ns);
    try testing.expectEqual(1, records[1].rows);
}

test "a container sets the clock, and transactions keep the hooks" {
    const App = zom.Container(.{
        .gateways = .{ .default = zom.memory.Gateway },
        .relations = .{ .items = .{ ItemSchema, .default } },
    });
    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();
    record_len = 0;
    ticks = 0;
    app.setPluginContext(.{ .clock = .{ .func = .{ .now = advance } } });

    try app.transaction(.default, {}, struct {
        fn f(_: void, tx: App.Relations) !void {
            _ = try tx.items.create(.{ .id = 1, .name = "a" }).commit();
        }
    }.f);
    try expectRecords(&.{ before(.insert, false), after(.insert, false, 1, null) });
}

test "instrumentation.log: a ready-made hook" {
    const LoggedSchema = zom.Schema(Item, "logged", .id, .{
        .plugins = .{ins.log(std.log.scoped(.zom))},
    });
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try zom.Relation(LoggedSchema, zom.memory.Gateway).init(&gw);
    // Logged at .debug, which the test runner hides; this checks it runs.
    _ = try rel.create(.{ .id = 1, .name = "a" }).commit();
    try testing.expectEqual(1, try rel.count());
}

test "no instrumentation plugin, no span" {
    // A span over a schema without `before` / `after` is an empty struct,
    // and its `end` only returns the result: nothing is measured or called.
    try testing.expect(!zom.plugins.instrumented(fixtures.Users.schema));
    try testing.expectEqual(0, @sizeOf(zom.plugins.Span(fixtures.Users.schema)));

    const Stamped = zom.Schema(struct { id: u32, created_at: i64, updated_at: i64 }, "stamped", .id, .{
        .plugins = .{zom.plugins.timestamps(.{})},
    });
    try testing.expect(!zom.plugins.instrumented(Stamped));
    try testing.expectEqual(0, @sizeOf(zom.plugins.Span(Stamped)));

    try testing.expect(zom.plugins.instrumented(ItemSchema));
}

// -- .fallback reads: the rows scanned ------------------------------------------

/// A gateway of one `items` dataset that filters on `eq` only, so a `gt`
/// on a `.fallback` relation runs in memory.
const EqOnlyGateway = struct {
    pub const adapter_name = "eq_only";
    pub const Config = struct {};

    items: Dataset(ItemSchema),

    pub fn Dataset(comptime S: type) type {
        return struct {
            const Q = zom.Query(S.Tuple);
            pub const supports: zom.Supports = .{};
            pub fn filterable(comptime _: []const u8, comptime op: zom.Op) bool {
                return op == .eq;
            }

            store: zom.memory.Store(S),

            pub fn read(self: *@This(), query: Q, a: std.mem.Allocator) ![]S.Tuple {
                return self.store.read(query, a);
            }
            pub fn count(self: *@This(), query: Q) !usize {
                return self.store.count(query);
            }
            pub fn insert(self: *@This(), t: S.Tuple) !S.Tuple {
                return self.store.insert(t);
            }
        };
    }

    pub fn init(a: std.mem.Allocator, _: Config) EqOnlyGateway {
        return .{ .items = .{ .store = .init(a) } };
    }
    pub fn deinit(self: *EqOnlyGateway) void {
        self.items.store.deinit();
    }
    pub fn dataset(self: *EqOnlyGateway, comptime S: type) !*Dataset(S) {
        if (S != ItemSchema) @compileError("eq_only only stores items");
        return &self.items;
    }
};

test "a .fallback read reports the rows the dataset returned, before the in-memory filter" {
    var gw = EqOnlyGateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try zom.Relation(ItemSchema, EqOnlyGateway).init(&gw);
    var i: u32 = 1;
    while (i <= 5) : (i += 1) _ = try rel.create(.{ .id = i, .name = "x" }).commit();
    record_len = 0;

    // `gt` runs in memory: the dataset returns all 5 rows, zom keeps 2.
    const got = try rel.allowFallback().where(.id, .gt, 3).toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(2, got.len);

    try testing.expectEqual(2, record_len);
    try testing.expectEqual(ins.Op.read, records[1].op);
    try testing.expectEqualStrings("eq_only", records[1].adapter);
    try testing.expectEqual(5, records[1].rows);
}
