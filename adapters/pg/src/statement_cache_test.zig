//! Named prepared statements (`runCached` in gateway.zig), against a live
//! Postgres. Skipped unless `ZOM_PG_URL` is set (see lint_test.zig). Each
//! test drops and recreates the `ps_items` table.
//!
//! The pool has one connection, so every call runs on the connection that
//! `pg_prepared_statements` describes.

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("root.zig");
const gateway = @import("gateway.zig");
const testing = std.testing;

const G = zom_pg.Gateway;

const Item = struct {
    id: u32,
    name: []const u8,
    qty: u8,
};
const Items = zom.Schema(Item, "ps_items", .id, .{});
const Rel = zom.Relation(Items, G);

const create_table =
    \\CREATE TABLE ps_items (
    \\  id bigint PRIMARY KEY,
    \\  name text NOT NULL,
    \\  qty smallint NOT NULL
    \\)
;

fn open(statement_cache_size: u16) !G {
    const u = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(u);
    var g = try G.init(testing.allocator, .{
        .io = testing.io,
        .url = u,
        .pool_size = 1,
        .statement_cache_size = statement_cache_size,
    });
    errdefer g.deinit();
    try g.exec("DROP TABLE IF EXISTS ps_items");
    try g.exec(create_table);
    return g;
}

fn close(g: *G) void {
    g.exec("DROP TABLE IF EXISTS ps_items") catch {};
    g.deinit();
}

const Prepared = struct {
    /// zom's named statements on the connection whose SQL contains `like`.
    statements: i64,
    /// How many times they have run since they were parsed.
    executions: i64,
};

/// Read with an unnamed statement, which `pg_prepared_statements` does
/// not list.
fn prepared(g: *G, like: []const u8) !Prepared {
    const conn = try g.source.acquire();
    defer g.source.release(conn);
    const result = try gateway.run(conn,
        \\SELECT count(*)::bigint, coalesce(sum(generic_plans + custom_plans), 0)::bigint
        \\FROM pg_prepared_statements
        \\WHERE name LIKE 'zom\_%' AND statement LIKE $1
    , &.{.{ .string = like }});
    defer result.deinit();
    errdefer result.drain() catch {};
    const row = (try gateway.next(conn, result)).?;
    const out: Prepared = .{ .statements = try row.get(i64, 0), .executions = try row.get(i64, 1) };
    while (try gateway.next(conn, result)) |_| {}
    return out;
}

fn add(g: *G, id: u32, name: []const u8) !void {
    const items = try Rel.init(g);
    const stored = try items.create(.{ .id = id, .name = name, .qty = 1 }).commitAlloc(testing.allocator);
    items.freeOne(testing.allocator, stored);
}

fn named(g: *G, name: []const u8) !usize {
    return (try Rel.init(g)).where(.name, .eq, name).count();
}

test "statement cache: a repeated statement is parsed once per connection" {
    var g = try open(256);
    defer close(&g);

    try add(&g, 1, "a");
    try add(&g, 2, "b");
    try add(&g, 3, "c");
    // One INSERT statement, parsed by the first call and run three times.
    try testing.expectEqual(Prepared{ .statements = 1, .executions = 3 }, try prepared(&g, "INSERT%"));

    // Other parameters, same text: the same statement.
    try testing.expectEqual(1, try named(&g, "a"));
    try testing.expectEqual(1, try named(&g, "b"));
    try testing.expectEqual(0, try named(&g, "z"));
    try testing.expectEqual(Prepared{ .statements = 1, .executions = 3 }, try prepared(&g, "%COUNT(*)%"));
}

test "statement cache: a schema change between runs re-prepares the statement" {
    var g = try open(256);
    defer close(&g);

    // INSERT ... RETURNING *: a new column changes the result's columns,
    // which Postgres refuses for a prepared statement (0A000).
    try add(&g, 1, "a");
    try g.exec("ALTER TABLE ps_items ADD COLUMN note text");
    try add(&g, 2, "b");
    try testing.expectEqual(Prepared{ .statements = 1, .executions = 1 }, try prepared(&g, "INSERT%"));

    // A selected column changing type does too.
    const items = try Rel.init(&g);
    const before = try items.order(.id, .asc).toSlice(testing.allocator);
    items.free(testing.allocator, before);
    try g.exec("ALTER TABLE ps_items ALTER COLUMN qty TYPE integer");
    const after = try items.order(.id, .asc).toSlice(testing.allocator);
    defer items.free(testing.allocator, after);
    try testing.expectEqual(2, after.len);
    try testing.expectEqual(1, after[1].qty);
}

test "statement cache: statements dropped behind its back are prepared again" {
    var g = try open(256);
    defer close(&g);

    try add(&g, 1, "a");
    try g.exec("DEALLOCATE ALL");
    // 26000, prepared statement does not exist: prepared again.
    try add(&g, 2, "b");
    try testing.expectEqual(Prepared{ .statements = 1, .executions = 1 }, try prepared(&g, "INSERT%"));
}

test "statement cache: inside a transaction the schema change fails the call, and the next one re-prepares" {
    var g = try open(256);
    defer close(&g);

    try add(&g, 1, "a");
    try testing.expectError(error.Database, g.transaction({}, struct {
        fn f(_: void, tx: *G) !void {
            try tx.exec("ALTER TABLE ps_items ADD COLUMN note text");
            try add(tx, 2, "b");
        }
    }.f));
    // Closed even though the transaction was aborted.
    try testing.expectEqual(Prepared{ .statements = 0, .executions = 0 }, try prepared(&g, "INSERT%"));
    try add(&g, 2, "b");
    try testing.expectEqual(2, try (try Rel.init(&g)).count());
}

test "statement cache: at most statement_cache_size statements per connection" {
    var g = try open(2);
    defer close(&g);

    try add(&g, 1, "a");
    try testing.expectEqual(1, try named(&g, "a"));
    try testing.expectEqual(1, try (try Rel.init(&g)).where(.qty, .eq, 1).count());
    try testing.expectEqual(1, try (try Rel.init(&g)).count());
    try testing.expectEqual(2, (try prepared(&g, "%")).statements);
}

test "statement cache: statement_cache_size 0 prepares nothing by name" {
    var g = try open(0);
    defer close(&g);

    try add(&g, 1, "a");
    try add(&g, 2, "b");
    try testing.expectEqual(1, try named(&g, "a"));
    try testing.expectEqual(0, (try prepared(&g, "%")).statements);
}
