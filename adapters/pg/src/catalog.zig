//! The `information_schema` and `pg_catalog` queries behind `verify`
//! (does a table match its struct?) and `introspect` (what structs would
//! match these tables?), so the two read the database the same way.
//!
//! `information_schema` names are domains over `name` and `varchar`, so
//! they are cast to `text` for pg.zig.

const std = @import("std");
const pg = @import("pg");
const gateway = @import("gateway.zig");

const Allocator = std.mem.Allocator;

/// The columns of table `$2` in schema `$1`, in table order.
pub const columns_sql =
    \\SELECT c.column_name::text,
    \\       c.data_type::text,
    \\       c.udt_name::text,
    \\       c.is_nullable::text = 'YES',
    \\       EXISTS (SELECT 1 FROM pg_catalog.pg_type t
    \\               JOIN pg_catalog.pg_namespace tn ON tn.oid = t.typnamespace
    \\               WHERE t.typname = c.udt_name::text AND tn.nspname = c.udt_schema::text AND t.typtype = 'e'),
    \\       c.udt_schema::text
    \\FROM information_schema.columns c
    \\WHERE c.table_schema::text = $1 AND c.table_name::text = $2
    \\ORDER BY c.ordinal_position
;

/// The schema (namespace) holding the table an unqualified `$1` means.
pub const namespace_sql =
    \\SELECT n.nspname::text
    \\FROM pg_catalog.pg_class cl
    \\JOIN pg_catalog.pg_namespace n ON n.oid = cl.relnamespace
    \\WHERE cl.oid = to_regclass(quote_ident($1))
;

/// The primary key columns of table `$2` in schema `$1`, in key order.
pub const primary_key_sql =
    \\SELECT k.column_name::text
    \\FROM information_schema.table_constraints tc
    \\JOIN information_schema.key_column_usage k
    \\  ON k.constraint_schema = tc.constraint_schema
    \\ AND k.constraint_name = tc.constraint_name
    \\ AND k.table_schema = tc.table_schema
    \\ AND k.table_name = tc.table_name
    \\WHERE tc.constraint_type = 'PRIMARY KEY'
    \\  AND tc.table_schema::text = $1 AND tc.table_name::text = $2
    \\ORDER BY k.ordinal_position
;

/// `$1` if it names a schema.
pub const schema_exists_sql =
    \\SELECT nspname::text FROM pg_catalog.pg_namespace WHERE nspname = $1
;

/// The base tables (not views) of schema `$1`, by name, bytewise, so the
/// order doesn't depend on the database's collation.
pub const tables_sql =
    \\SELECT table_name::text
    \\FROM information_schema.tables
    \\WHERE table_schema::text = $1 AND table_type = 'BASE TABLE'
    \\ORDER BY table_name::text COLLATE "C"
;

/// The labels of enum type `$2` in schema `$1`, in sort order.
pub const enum_labels_sql =
    \\SELECT e.enumlabel::text
    \\FROM pg_catalog.pg_enum e
    \\JOIN pg_catalog.pg_type t ON t.oid = e.enumtypid
    \\JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace
    \\WHERE n.nspname = $1 AND t.typname = $2
    \\ORDER BY e.enumsortorder
;

pub const Column = struct {
    name: []const u8,
    /// `information_schema.columns.data_type`: `integer`, `character
    /// varying`, `USER-DEFINED`, ...
    data_type: []const u8,
    /// The type's own name (`int4`, `varchar`, an enum's name).
    udt_name: []const u8,
    /// The schema `udt_name` lives in.
    udt_schema: []const u8,
    nullable: bool,
    is_enum: bool,

    /// How a message names the type: an enum's or other user-defined
    /// type's own name, else the SQL name (`character varying`).
    pub fn typeName(c: Column) []const u8 {
        return if (std.mem.eql(u8, c.data_type, "USER-DEFINED")) c.udt_name else c.data_type;
    }
};

pub fn findColumn(columns: []const Column, name: []const u8) ?Column {
    for (columns) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

/// The first column of every row, copied into `scratch`.
pub fn queryStrings(conn: *pg.Conn, scratch: Allocator, sql: []const u8, params: []const gateway.Value) ![]const []const u8 {
    const result = try gateway.run(conn, sql, params);
    defer result.deinit();
    errdefer result.drain() catch {};
    var out: std.ArrayList([]const u8) = .empty;
    while (try gateway.next(conn, result)) |row| {
        try out.append(scratch, try scratch.dupe(u8, try getText(conn, &row, 0)));
    }
    return out.items;
}

pub fn queryColumns(conn: *pg.Conn, scratch: Allocator, namespace: []const u8, table: []const u8) ![]const Column {
    const result = try gateway.run(conn, columns_sql, &.{ .{ .string = namespace }, .{ .string = table } });
    defer result.deinit();
    errdefer result.drain() catch {};
    var out: std.ArrayList(Column) = .empty;
    while (try gateway.next(conn, result)) |row| {
        try out.append(scratch, .{
            .name = try scratch.dupe(u8, try getText(conn, &row, 0)),
            .data_type = try scratch.dupe(u8, try getText(conn, &row, 1)),
            .udt_name = try scratch.dupe(u8, try getText(conn, &row, 2)),
            .nullable = row.get(bool, 3) catch |err| return gateway.mapError(conn, err),
            .is_enum = row.get(bool, 4) catch |err| return gateway.mapError(conn, err),
            .udt_schema = try scratch.dupe(u8, try getText(conn, &row, 5)),
        });
    }
    return out.items;
}

fn getText(conn: *pg.Conn, row: *const pg.Row, col: usize) ![]const u8 {
    return row.get([]const u8, col) catch |err| gateway.mapError(conn, err);
}
