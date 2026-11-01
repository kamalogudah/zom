//! `Gateway.introspect(allocator, schema)`: the tables of one Postgres
//! schema as a `zom_sql.infer.Catalog`, ready for `zom_sql.infer.render`.
//! `zom-pg-infer` is this plus a file write.
//!
//! It reads the same `information_schema` columns as `verify` and maps them
//! with `zigTypeFor`, so `verify` accepts every struct generated from it.

const std = @import("std");
const infer = @import("zom_sql").infer;
const gateway = @import("gateway.zig");
const catalog = @import("catalog.zig");
const zigTypeFor = @import("verify.zig").zigTypeFor;

const Allocator = std.mem.Allocator;
const Gateway = gateway.Gateway;

/// A catalog and the arena its strings live in.
pub const Introspection = struct {
    arena: std.heap.ArenaAllocator,
    catalog: infer.Catalog,

    pub fn deinit(self: *Introspection) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Every base table of `schema` (views are left out), by name, with the
/// Postgres enums their columns use, by name. `error.SchemaNotFound` when
/// there is no such schema; a schema the connection's role can't read
/// looks empty, as `information_schema` only lists what it may see.
pub fn introspect(self: *Gateway, allocator: Allocator, schema: []const u8) !Introspection {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const conn = try self.source.acquire();
    defer self.source.release(conn);

    if ((try catalog.queryStrings(conn, a, catalog.schema_exists_sql, &.{.{ .string = schema }})).len == 0)
        return error.SchemaNotFound;

    const names = try catalog.queryStrings(conn, a, catalog.tables_sql, &.{.{ .string = schema }});
    const tables = try a.alloc(infer.Table, names.len);
    var enums: std.ArrayList(infer.Enum) = .empty;
    // (udt_schema, udt_name) of each enum in `enums`, to read each once.
    var enum_keys: std.ArrayList([2][]const u8) = .empty;

    for (names, tables) |name, *table| {
        const columns = try catalog.queryColumns(conn, a, schema, name);
        const out = try a.alloc(infer.Column, columns.len);
        for (columns, out) |c, *col| {
            col.* = .{
                .name = c.name,
                .type = if (c.is_enum) .{ .@"enum" = c.udt_name } else zigTypeFor(c.data_type),
                .sql_type = c.typeName(),
                .nullable = c.nullable,
            };
            if (!c.is_enum) continue;
            for (enum_keys.items) |k| {
                if (std.mem.eql(u8, k[0], c.udt_schema) and std.mem.eql(u8, k[1], c.udt_name)) break;
            } else {
                try enum_keys.append(a, .{ c.udt_schema, c.udt_name });
                try enums.append(a, .{
                    .name = c.udt_name,
                    .labels = try catalog.queryStrings(conn, a, catalog.enum_labels_sql, &.{ .{ .string = c.udt_schema }, .{ .string = c.udt_name } }),
                });
            }
        }
        table.* = .{
            .name = name,
            .columns = out,
            .primary_key = try catalog.queryStrings(conn, a, catalog.primary_key_sql, &.{ .{ .string = schema }, .{ .string = name } }),
        };
    }

    std.mem.sort(infer.Enum, enums.items, {}, struct {
        fn lessThan(_: void, l: infer.Enum, r: infer.Enum) bool {
            return std.mem.lessThan(u8, l.name, r.name);
        }
    }.lessThan);

    return .{ .arena = arena, .catalog = .{
        .schema = try a.dupe(u8, schema),
        .tables = tables,
        .enums = enums.items,
    } };
}
