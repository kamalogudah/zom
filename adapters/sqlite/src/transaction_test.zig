//! `transaction`, the error mapping and the statement cache, on SQLite.
//! Each test opens its own in-memory database, except those that need two
//! connections to one database, which use a file under `.zig-cache/tmp`.

const std = @import("std");
const zom = @import("zom");
const zom_sqlite = @import("root.zig");
const c = zom_sqlite.c;
const testing = std.testing;

const G = zom_sqlite.Gateway;

const Item = struct {
    id: u32,
    name: []const u8,
    qty: u8,
};
const Items = zom.Schema(Item, "tx_items", .id, .{});
const Rel = zom.Relation(Items, G);

const create_table =
    \\CREATE TABLE tx_items (
    \\  id INTEGER PRIMARY KEY,
    \\  name TEXT NOT NULL UNIQUE,
    \\  qty INTEGER NOT NULL CHECK (qty < 256)
    \\)
;

fn open() !G {
    var g = try G.init(testing.allocator, .{});
    errdefer g.deinit();
    try g.exec(create_table);
    return g;
}

fn count(g: *G) !usize {
    return (try Rel.init(g)).count();
}

fn add(tx: *G, id: u32, name: []const u8) !void {
    const stored = try (try Rel.init(tx)).create(.{ .id = id, .name = name, .qty = 1 }).commitAlloc(testing.allocator);
    (try Rel.init(tx)).freeOne(testing.allocator, stored);
}

/// A database file in a fresh `.zig-cache/tmp` directory, for tests that
/// need two connections to one database.
const TmpDb = struct {
    tmp: testing.TmpDir,
    path: [64]u8 = undefined,
    len: usize = 0,

    fn init() TmpDb {
        var t: TmpDb = .{ .tmp = testing.tmpDir(.{}) };
        t.len = (std.fmt.bufPrint(&t.path, ".zig-cache/tmp/{s}/db.sqlite", .{t.tmp.sub_path}) catch unreachable).len;
        return t;
    }
    fn file(self: *const TmpDb) []const u8 {
        return self.path[0..self.len];
    }
    fn deinit(self: *TmpDb) void {
        self.tmp.cleanup();
    }
};

test "transaction: a commit is visible after the call" {
    var g = try open();
    defer g.deinit();

    const n = try g.transaction({}, struct {
        fn f(_: void, tx: *G) !usize {
            try add(tx, 1, "a");
            try add(tx, 2, "b");
            return count(tx);
        }
    }.f);
    try testing.expectEqual(2, n);
    try testing.expectEqual(2, try count(&g));
}

test "transaction: another connection sees nothing until the commit" {
    var db = TmpDb.init();
    defer db.deinit();
    var g = try G.init(testing.allocator, .{ .path = db.file(), .journal_mode = .wal });
    defer g.deinit();
    try g.exec(create_table);
    var other = try G.init(testing.allocator, .{ .path = db.file() });
    defer other.deinit();

    const Ctx = struct { other: *G, seen_inside: usize = 99 };
    var ctx: Ctx = .{ .other = &other };
    try g.transaction(&ctx, struct {
        fn f(cx: *Ctx, tx: *G) !void {
            try add(tx, 1, "a");
            cx.seen_inside = try count(cx.other);
        }
    }.f);
    try testing.expectEqual(0, ctx.seen_inside);
    try testing.expectEqual(1, try count(&other));
}

test "transaction: an error rolls back and comes back unchanged" {
    var g = try open();
    defer g.deinit();

    const result = g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 1, "a");
            try add(tx, 2, "b");
            return error.Boom;
        }
    }.f);
    try testing.expectError(error.Boom, result);
    try testing.expectEqual(0, try count(&g));

    // So does a database error, as the shared name.
    const dup = g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 1, "a");
            try add(tx, 1, "again");
        }
    }.f);
    try testing.expectError(error.DuplicatePrimaryKey, dup);
    try testing.expectEqual(0, try count(&g));
    try testing.expect(c.sqlite3_get_autocommit(g.handle()) != 0);

    try add(&g, 3, "c");
    try testing.expectEqual(1, try count(&g));
}

test "transaction: f may return a plain value" {
    var g = try open();
    defer g.deinit();
    const v = try g.transaction(@as(u32, 41), struct {
        fn f(x: u32, _: *G) u32 {
            return x + 1;
        }
    }.f);
    try testing.expectEqual(42, v);
}

test "transaction: nested is a savepoint, rolled back on its own" {
    var g = try open();
    defer g.deinit();

    try g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 1, "a");
            const inner = tx.transaction({}, struct {
                fn f(_: void, inner_tx: *G) !void {
                    try add(inner_tx, 2, "b");
                    try add(inner_tx, 1, "dup");
                }
            }.f);
            try testing.expectError(error.DuplicatePrimaryKey, inner);
            try add(tx, 3, "c");
            try testing.expectEqual(2, try count(tx));
        }
    }.f);

    const rel = try Rel.init(&g);
    const rows = try rel.order(.id, .asc).toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);
    try testing.expectEqual(2, rows.len);
    try testing.expectEqual(1, rows[0].id);
    try testing.expectEqual(3, rows[1].id);
}

test "transaction: an error caught inside f leaves the transaction usable" {
    var g = try open();
    defer g.deinit();

    try g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 1, "a");
            // Unlike Postgres, SQLite undoes only the failed statement.
            try testing.expectError(error.DuplicatePrimaryKey, add(tx, 1, "dup"));
            try add(tx, 2, "b");
        }
    }.f);
    try testing.expectEqual(2, try count(&g));
}

test "transaction: inside the caller's own BEGIN, it is a savepoint" {
    var g = try open();
    defer g.deinit();

    try g.exec("BEGIN");
    try add(&g, 1, "a");
    const result = g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 2, "b");
            return error.Boom;
        }
    }.f);
    try testing.expectError(error.Boom, result);
    // Only the savepoint went; the caller's transaction is still open.
    try testing.expect(c.sqlite3_get_autocommit(g.handle()) == 0);
    try g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 3, "c");
        }
    }.f);
    try testing.expect(c.sqlite3_get_autocommit(g.handle()) == 0);
    try g.exec("COMMIT");
    try testing.expectEqual(2, try count(&g));
}

test "transaction: insertMany inside is all or nothing and leaves it usable" {
    var g = try open();
    defer g.deinit();

    try g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            const rel = try Rel.init(tx);
            try add(tx, 1, "a");
            const batch = [_]Item{ .{ .id = 2, .name = "b", .qty = 1 }, .{ .id = 1, .name = "dup", .qty = 1 } };
            try testing.expectError(error.DuplicatePrimaryKey, rel.createMany(&batch).commit());
            try testing.expectEqual(1, try count(tx));
            try testing.expectEqual(2, try rel.createMany(&.{ .{ .id = 2, .name = "b", .qty = 1 }, .{ .id = 3, .name = "c", .qty = 1 } }).commit());
        }
    }.f);
    try testing.expectEqual(3, try count(&g));
}

test "errors: every unique violation is DuplicatePrimaryKey, lastError says which" {
    var g = try open();
    defer g.deinit();

    try add(&g, 1, "a");
    try testing.expectError(error.DuplicatePrimaryKey, add(&g, 1, "b"));
    try testing.expectEqual(c.SQLITE_CONSTRAINT_PRIMARYKEY, G.lastError().?.code);
    try testing.expectEqual(c.SQLITE_CONSTRAINT, G.lastError().?.primary());
    try testing.expectEqualStrings("UNIQUE constraint failed: tx_items.id", G.lastError().?.message);

    try testing.expectError(error.DuplicatePrimaryKey, add(&g, 2, "a"));
    try testing.expectEqual(c.SQLITE_CONSTRAINT_UNIQUE, G.lastError().?.code);
    try testing.expectEqualStrings("UNIQUE constraint failed: tx_items.name", G.lastError().?.message);
}

test "errors: a missing table is NotFound, anything else Database" {
    var g = try open();
    defer g.deinit();

    try g.exec("DROP TABLE tx_items");
    try testing.expectError(error.NotFound, count(&g));
    try testing.expectEqualStrings("no such table: tx_items", G.lastError().?.message);

    try testing.expectError(error.Database, g.exec("SELEC 1"));
    try testing.expectEqual(c.SQLITE_ERROR, G.lastError().?.code);
    try testing.expect(std.mem.indexOf(u8, G.lastError().?.message, "SELEC") != null);
}

test "errors: a CHECK constraint is Database, and a value past i64 is ValueOutOfRange" {
    var g = try open();
    defer g.deinit();
    try add(&g, 1, "a");

    // The column holds 300 and the CHECK refuses it.
    try testing.expectError(error.Database, g.exec("UPDATE tx_items SET qty = 300"));
    try testing.expectEqual(c.SQLITE_CONSTRAINT_CHECK, G.lastError().?.code);

    const Big = struct { id: u64, name: []const u8, qty: u8 };
    const BigItems = zom.Schema(Big, "tx_items", .id, .{});
    const big = try zom.Relation(BigItems, G).init(&g);
    try testing.expectError(error.ValueOutOfRange, big.create(.{ .id = std.math.maxInt(u64), .name = "b", .qty = 1 }).commitAlloc(testing.allocator));
}

test "errors: a value that doesn't fit its field is ValueOutOfRange; the wrong type ColumnTypeMismatch" {
    var g = try G.init(testing.allocator, .{});
    defer g.deinit();
    // Not STRICT, and no CHECK: SQLite keeps what it is given.
    try g.exec("CREATE TABLE tx_items (id INTEGER PRIMARY KEY, name TEXT NOT NULL, qty INTEGER NOT NULL)");
    try g.exec("INSERT INTO tx_items (id, name, qty) VALUES (1, 'a', 255)");
    const rel = try Rel.init(&g);
    const one = (try rel.byPk(1).one(testing.allocator)).?;
    rel.freeOne(testing.allocator, one);

    try g.exec("UPDATE tx_items SET qty = -1");
    try testing.expectError(error.ValueOutOfRange, rel.toSlice(testing.allocator));
    try g.exec("UPDATE tx_items SET qty = 'lots'");
    try testing.expectError(error.ColumnTypeMismatch, rel.toSlice(testing.allocator));
}

test "errors: read_only refuses writes, a missing file can't be opened" {
    var db = TmpDb.init();
    defer db.deinit();
    {
        var g = try G.init(testing.allocator, .{ .path = db.file() });
        defer g.deinit();
        try g.exec(create_table);
    }
    var ro = try G.init(testing.allocator, .{ .path = db.file(), .mode = .read_only });
    defer ro.deinit();
    try testing.expectEqual(0, try count(&ro));
    try testing.expectError(error.ReadOnly, add(&ro, 1, "a"));

    var missing: [80]u8 = undefined;
    const path = try std.fmt.bufPrint(&missing, ".zig-cache/tmp/{s}/missing.sqlite", .{db.tmp.sub_path});
    try testing.expectError(error.ConnectionFailed, G.init(testing.allocator, .{ .path = path, .mode = .read_write }));
}

test "errors: a write lock held elsewhere past busy_timeout_ms is Busy" {
    var db = TmpDb.init();
    defer db.deinit();
    var g = try G.init(testing.allocator, .{ .path = db.file(), .busy_timeout_ms = 0 });
    defer g.deinit();
    try g.exec(create_table);
    var other = try G.init(testing.allocator, .{ .path = db.file(), .busy_timeout_ms = 0 });
    defer other.deinit();

    try other.exec("BEGIN IMMEDIATE");
    try testing.expectError(error.Busy, add(&g, 1, "a"));
    try testing.expectError(error.Busy, g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 2, "b");
        }
    }.f));
    try other.exec("ROLLBACK");
    try add(&g, 1, "a");
}

test "the gateway has the transaction capability" {
    try testing.expect(zom.Adapter(G).has(Items, .transaction));
}

// -- statement cache ----------------------------------------------------------

test "statement cache: a repeated statement is prepared once" {
    var g = try open();
    defer g.deinit();
    try add(&g, 1, "a");
    const rel = try Rel.init(&g);
    const before = g.conn.prepared;
    for (0..5) |_| {
        const row = (try rel.byPk(1).one(testing.allocator)).?;
        rel.freeOne(testing.allocator, row);
    }
    try testing.expectEqual(before + 1, g.conn.prepared);
}

test "statement cache: a schema change between runs is picked up" {
    var g = try open();
    defer g.deinit();
    try add(&g, 1, "a");
    try testing.expectEqual(1, try count(&g));
    try g.exec("DROP TABLE tx_items");
    try g.exec(create_table);
    try testing.expectEqual(0, try count(&g));
}

test "statement cache: at most statement_cache_size statements, and 0 keeps none" {
    var g = try G.init(testing.allocator, .{ .statement_cache_size = 2 });
    defer g.deinit();
    try g.exec(create_table);
    const rel = try Rel.init(&g);
    for (1..6) |i| _ = try rel.where(.id, .eq, @as(u32, @intCast(i))).limit(i).count();
    try testing.expectEqual(2, g.conn.cache.count());

    var none = try G.init(testing.allocator, .{ .statement_cache_size = 0 });
    defer none.deinit();
    try none.exec(create_table);
    const before = none.conn.prepared;
    for (0..3) |_| _ = try count(&none);
    try testing.expectEqual(before + 3, none.conn.prepared);
    try testing.expectEqual(0, none.conn.cache.count());
}

// -- container.transaction ----------------------------------------------------

const Note = struct { id: u32, text: []const u8 };
const Notes = zom.Schema(Note, "notes", .id, .{});

/// `items` on SQLite, `notes` in memory, to check that only the named
/// gateway's relations join the transaction.
const App = zom.Container(.{
    .gateways = .{ .db = G, .scratch = zom.memory.Gateway },
    .relations = .{ .items = .{ Items, .db }, .notes = .{ Notes, .scratch } },
});

fn openApp(app: *App) !void {
    try app.init(testing.allocator, .{ .db = .{} });
    errdefer app.deinit();
    try app.gateways.db.exec(create_table);
}

fn addItem(items: Rel, id: u32, name: []const u8) !void {
    const stored = try items.create(.{ .id = id, .name = name, .qty = 1 }).commitAlloc(testing.allocator);
    items.freeOne(testing.allocator, stored);
}

test "container.transaction on sqlite: commits" {
    var app: App = undefined;
    try openApp(&app);
    defer app.deinit();

    const n = try app.transaction(.db, {}, struct {
        fn f(_: void, tx: App.Relations) !usize {
            try addItem(tx.items, 1, "a");
            try addItem(tx.items, 2, "b");
            return tx.items.count();
        }
    }.f);
    try testing.expectEqual(2, n);
    try testing.expectEqual(2, try app.relations.items.count());
}

test "container.transaction on sqlite: an error rolls back the gateway's relations only" {
    var app: App = undefined;
    try openApp(&app);
    defer app.deinit();

    const result = app.transaction(.db, {}, struct {
        fn f(_: void, tx: App.Relations) !void {
            try addItem(tx.items, 1, "a");
            _ = try tx.notes.create(.{ .id = 1, .text = "outside the transaction" }).commit();
            try addItem(tx.items, 1, "dup");
        }
    }.f);
    try testing.expectError(error.DuplicatePrimaryKey, result);
    try testing.expectEqual(0, try app.relations.items.count());
    try testing.expectEqual(1, try app.relations.notes.count());

    try addItem(app.relations.items, 3, "c");
    try testing.expectEqual(1, try app.relations.items.count());
}
