//! `transaction` and the error mapping, against a live Postgres. Skipped
//! unless `ZOM_PG_URL` is set (see lint_test.zig). Each test drops and
//! recreates the `tx_items` table.

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const G = zom_pg.Gateway;

const Item = struct {
    id: u32,
    name: []const u8,
    qty: u8,
};
const Items = zom.Schema(Item, "tx_items", .id, .{});
const Rel = zom.Relation(Items, G);

/// `qty` is a `u8` in a `smallint`, so 300 passes zom's checks on insert
/// paths that don't check, and a `CHECK` makes Postgres refuse it too.
const create_table =
    \\CREATE TABLE tx_items (
    \\  id bigint PRIMARY KEY,
    \\  name text NOT NULL UNIQUE,
    \\  qty smallint NOT NULL
    \\)
;

/// Two connections: one for a transaction, one to look from outside it.
fn open() !G {
    const u = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(u);
    var g = try G.init(testing.allocator, .{ .io = testing.io, .url = u, .pool_size = 2 });
    errdefer g.deinit();
    try g.exec("DROP TABLE IF EXISTS tx_items");
    try g.exec(create_table);
    return g;
}

fn close(g: *G) void {
    g.exec("DROP TABLE IF EXISTS tx_items") catch {};
    g.deinit();
}

fn count(g: *G) !usize {
    return (try Rel.init(g)).count();
}

fn add(tx: *G, id: u32, name: []const u8) !void {
    const stored = try (try Rel.init(tx)).create(.{ .id = id, .name = name, .qty = 1 }).commitAlloc(testing.allocator);
    (try Rel.init(tx)).freeOne(testing.allocator, stored);
}

test "transaction: a commit is visible after the call, and not before" {
    var g = try open();
    defer close(&g);

    const Ctx = struct { outer: *G, seen_inside: usize = 99 };
    var ctx: Ctx = .{ .outer = &g };
    const n = try g.transaction(&ctx, struct {
        fn f(c: *Ctx, tx: *G) !usize {
            try add(tx, 1, "a");
            try add(tx, 2, "b");
            // Every call on `tx` is on the pinned connection...
            const inside = try count(tx);
            // ...and the outer gateway, on the other one, can't see it yet.
            c.seen_inside = try count(c.outer);
            return inside;
        }
    }.f);
    try testing.expectEqual(2, n);
    try testing.expectEqual(0, ctx.seen_inside);
    try testing.expectEqual(2, try count(&g));
}

test "transaction: an error rolls back and comes back unchanged" {
    var g = try open();
    defer close(&g);

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

    // The connection went back to the pool clean: both still work.
    try add(&g, 3, "c");
    try add(&g, 4, "d");
    try testing.expectEqual(2, try count(&g));
}

test "transaction: f may return a plain value" {
    var g = try open();
    defer close(&g);
    const v = try g.transaction(@as(u32, 41), struct {
        fn f(x: u32, _: *G) u32 {
            return x + 1;
        }
    }.f);
    try testing.expectEqual(42, v);
}

test "transaction: nested is a savepoint, rolled back on its own" {
    var g = try open();
    defer close(&g);

    try g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 1, "a");
            // The inner one fails; only its rows go.
            const inner = tx.transaction({}, struct {
                fn f(_: void, inner_tx: *G) !void {
                    try add(inner_tx, 2, "b");
                    try add(inner_tx, 1, "dup");
                }
            }.f);
            try testing.expectError(error.DuplicatePrimaryKey, inner);
            // The outer transaction is still usable.
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

test "transaction: an error swallowed without a savepoint fails the commit" {
    var g = try open();
    defer close(&g);

    const result = g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try add(tx, 1, "a");
            add(tx, 1, "dup") catch |err| try testing.expectEqual(error.DuplicatePrimaryKey, err);
            // Postgres aborted the transaction; later calls are refused.
            try testing.expectError(error.Database, add(tx, 2, "b"));
            try testing.expectEqualStrings("25P02", G.lastError().?.code); // in_failed_sql_transaction
        }
    }.f);
    try testing.expectError(error.Database, result);
    try testing.expectEqual(0, try count(&g));
}

test "transaction: insertMany inside is all or nothing and leaves it usable" {
    var g = try open();
    defer close(&g);

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

test "errors: every unique violation is DuplicatePrimaryKey, lastError names the constraint" {
    var g = try open();
    defer close(&g);

    try add(&g, 1, "a");
    try testing.expectError(error.DuplicatePrimaryKey, add(&g, 1, "b"));
    try testing.expectEqualStrings("tx_items_pkey", G.lastError().?.constraint.?);
    try testing.expectEqualStrings("tx_items", G.lastError().?.table.?);

    // A UNIQUE column that isn't the key maps the same way.
    try testing.expectError(error.DuplicatePrimaryKey, add(&g, 2, "a"));
    try testing.expectEqualStrings("tx_items_name_key", G.lastError().?.constraint.?);
}

test "errors: a missing table is NotFound, anything else Database" {
    var g = try open();
    defer close(&g);

    try g.exec("DROP TABLE tx_items");
    try testing.expectError(error.NotFound, count(&g));
    try testing.expectEqualStrings("42P01", G.lastError().?.code);

    try testing.expectError(error.Database, g.exec("SELEC 1"));
    const e = G.lastError().?;
    try testing.expectEqualStrings("42601", e.code); // syntax_error
    try testing.expectEqualStrings("ERROR", e.severity);
    try testing.expect(std.mem.indexOf(u8, e.message, "SELEC") != null);

    try testing.expectError(error.ValueOutOfRange, g.exec("SELECT 40000::smallint"));
    try testing.expectEqualStrings("22003", G.lastError().?.code);
}

test "the gateway has the transaction capability" {
    try testing.expect(zom.Adapter(G).has(Items, .transaction));
}

// -- container.transaction ----------------------------------------------------

const Note = struct { id: u32, text: []const u8 };
const Notes = zom.Schema(Note, "notes", .id, .{});

/// `items` on Postgres, `notes` in memory, to check that only the named
/// gateway's relations join the transaction.
const App = zom.Container(.{
    .gateways = .{ .db = G, .scratch = zom.memory.Gateway },
    .relations = .{ .items = .{ Items, .db }, .notes = .{ Notes, .scratch } },
});

/// Initialises `app` on ZOM_PG_URL. The table comes from `open`, called
/// first on a gateway of its own.
fn openApp(app: *App) !void {
    const u = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(u);
    try app.init(testing.allocator, .{ .db = .{ .io = testing.io, .url = u, .pool_size = 2 } });
}

fn addItem(items: Rel, id: u32, name: []const u8) !void {
    const stored = try items.create(.{ .id = id, .name = name, .qty = 1 }).commitAlloc(testing.allocator);
    items.freeOne(testing.allocator, stored);
}

test "container.transaction on pg: commits, on the pinned connection" {
    var g = try open();
    defer close(&g);
    var app: App = undefined;
    try openApp(&app);
    defer app.deinit();

    const Ctx = struct { outer: Rel, seen_inside: usize = 99 };
    var ctx: Ctx = .{ .outer = app.relations.items };
    const n = try app.transaction(.db, &ctx, struct {
        fn f(c: *Ctx, tx: App.Relations) !usize {
            try addItem(tx.items, 1, "a");
            try addItem(tx.items, 2, "b");
            // The container's own relation is on another connection.
            c.seen_inside = try c.outer.count();
            return tx.items.count();
        }
    }.f);
    try testing.expectEqual(2, n);
    try testing.expectEqual(0, ctx.seen_inside);
    try testing.expectEqual(2, try app.relations.items.count());
}

test "container.transaction on pg: an error rolls back the gateway's relations only" {
    var g = try open();
    defer close(&g);
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

    // The pool is still usable.
    try addItem(app.relations.items, 3, "c");
    try testing.expectEqual(1, try app.relations.items.count());
}
