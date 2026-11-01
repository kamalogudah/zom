//! `Gateway.verify(S, diagnostics)`: a startup check that the table behind
//! a schema matches its Zig struct.
//!
//! A Zig schema can't be inferred from the database at compile time, so
//! this is the next best thing: compare `information_schema` with `S.Tuple`
//! once, at startup, and fail fast with every mismatch at once, instead of
//! one `error.MissingColumn` or `error.ColumnTypeMismatch` per query later.
//!
//! The table is the one an unqualified `S.name` resolves to on the
//! connection's `search_path`, which is the one the gateway's statements
//! use (`public`, by default).

const std = @import("std");
const gateway = @import("gateway.zig");

const Allocator = std.mem.Allocator;
const Gateway = gateway.Gateway;
const log = std.log.scoped(.zom_pg);

/// One way a table differs from its schema. Formatted with `{f}` it reads
/// `users.age: Zig u8 vs pg text`.
pub const Mismatch = struct {
    /// `S.name`.
    table: []const u8,
    /// The tuple field, or null for the table itself (`missing_table`, the
    /// primary key problems).
    column: ?[]const u8 = null,
    problem: Problem,

    pub const Problem = union(enum) {
        /// `S.name` doesn't resolve to a table on the `search_path`.
        missing_table,
        /// The table has no column named after the field.
        missing_column: struct { zig: []const u8 },
        /// The column's type can't hold the field (see `pgTypesFor`).
        wrong_type: struct { zig: []const u8, pg: []const u8 },
        /// A non-optional field on a nullable column: reading a NULL
        /// would fail with `error.UnexpectedNull`.
        nullable_column: struct { zig: []const u8 },
        /// An optional field on a `NOT NULL` column: writing a null
        /// would fail with a not-null violation.
        not_null_column: struct { zig: []const u8 },
        /// The table has no primary key; the schema says `expected`.
        no_primary_key: struct { expected: []const u8 },
        /// The table's primary key is `actual` (its columns, comma
        /// separated), not `expected`.
        wrong_primary_key: struct { expected: []const u8, actual: []const u8 },
    };

    pub fn format(m: Mismatch, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll(m.table);
        if (m.column) |c| try w.print(".{s}", .{c});
        try w.writeAll(": ");
        switch (m.problem) {
            .missing_table => try w.writeAll("no such table"),
            .missing_column => |p| try w.print("Zig {s} vs no column", .{p.zig}),
            .wrong_type => |p| try w.print("Zig {s} vs pg {s}", .{ p.zig, p.pg }),
            .nullable_column => |p| try w.print("Zig {s} vs pg nullable column (make the field optional or the column NOT NULL)", .{p.zig}),
            .not_null_column => |p| try w.print("Zig {s} vs pg NOT NULL column", .{p.zig}),
            .no_primary_key => |p| try w.print("no primary key, expected ({s})", .{p.expected}),
            .wrong_primary_key => |p| try w.print("primary key is ({s}), expected ({s})", .{ p.actual, p.expected }),
        }
    }
};

/// Every mismatch `verify` found, in field order. The strings live in
/// `arena` (the Zig names are static), so `deinit` frees them all. One
/// `Diagnostics` may collect several `verify` calls.
pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    mismatches: std.ArrayList(Mismatch) = .empty,

    pub fn init(allocator: Allocator) Diagnostics {
        return .{ .arena = .init(allocator) };
    }

    pub fn deinit(self: *Diagnostics) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// One mismatch per line.
    pub fn format(self: Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.mismatches.items, 0..) |m, i| {
            if (i != 0) try w.writeByte('\n');
            try w.print("{f}", .{m});
        }
    }

    fn add(self: *Diagnostics, m: Mismatch) !void {
        try self.mismatches.append(self.arena.allocator(), m);
    }

    fn dupe(self: *Diagnostics, s: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, s);
    }
};

/// The columns `information_schema` reports for the table `$1` resolves
/// to. `information_schema` names are domains over `name` and `varchar`,
/// so they are cast to `text` for pg.zig.
const columns_sql =
    \\SELECT c.column_name::text,
    \\       c.data_type::text,
    \\       c.udt_name::text,
    \\       c.is_nullable::text = 'YES',
    \\       EXISTS (SELECT 1 FROM pg_catalog.pg_type t
    \\               JOIN pg_catalog.pg_namespace tn ON tn.oid = t.typnamespace
    \\               WHERE t.typname = c.udt_name::text AND tn.nspname = c.udt_schema::text AND t.typtype = 'e')
    \\FROM information_schema.columns c
    \\WHERE c.table_schema::text = $1 AND c.table_name::text = $2
;

/// The schema (namespace) holding the table an unqualified `$1` means.
const namespace_sql =
    \\SELECT n.nspname::text
    \\FROM pg_catalog.pg_class cl
    \\JOIN pg_catalog.pg_namespace n ON n.oid = cl.relnamespace
    \\WHERE cl.oid = to_regclass(quote_ident($1))
;

const primary_key_sql =
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

const Column = struct {
    name: []const u8,
    data_type: []const u8,
    udt_name: []const u8,
    nullable: bool,
    is_enum: bool,

    /// How a mismatch names the type: an enum's or other user-defined
    /// type's own name, else the SQL name (`character varying`).
    fn typeName(c: Column) []const u8 {
        return if (std.mem.eql(u8, c.data_type, "USER-DEFINED")) c.udt_name else c.data_type;
    }
};

pub fn verify(self: *Gateway, comptime S: type, diagnostics: ?*Diagnostics) !void {
    var own: Diagnostics = .init(self.allocator);
    defer own.deinit();
    const diag = diagnostics orelse &own;
    const before = diag.mismatches.items.len;

    var scratch: std.heap.ArenaAllocator = .init(self.allocator);
    defer scratch.deinit();
    try check(self, S, diag, scratch.allocator());

    const found = diag.mismatches.items[before..];
    if (found.len == 0) return;
    if (diagnostics == null) {
        for (found) |m| log.err("schema mismatch: {f}", .{m});
    }
    return error.SchemaMismatch;
}

fn check(self: *Gateway, comptime S: type, diag: *Diagnostics, scratch: Allocator) !void {
    const fields = @typeInfo(S.Tuple).@"struct".fields;
    const table = S.name;

    const conn = try self.source.acquire();
    defer self.source.release(conn);

    const namespace = (try queryStrings(conn, scratch, namespace_sql, &.{.{ .string = table }})).first() orelse
        return diag.add(.{ .table = table, .problem = .missing_table });

    const columns = try queryColumns(conn, scratch, namespace, table);
    inline for (fields) |f| {
        const zig = @typeName(f.type);
        const optional = @typeInfo(f.type) == .optional;
        if (find(columns, f.name)) |col| {
            if (!accepts(f.type, col)) {
                try diag.add(.{ .table = table, .column = f.name, .problem = .{ .wrong_type = .{ .zig = zig, .pg = try diag.dupe(col.typeName()) } } });
            } else if (col.nullable and !optional) {
                try diag.add(.{ .table = table, .column = f.name, .problem = .{ .nullable_column = .{ .zig = zig } } });
            } else if (!col.nullable and optional) {
                try diag.add(.{ .table = table, .column = f.name, .problem = .{ .not_null_column = .{ .zig = zig } } });
            }
        } else {
            try diag.add(.{ .table = table, .column = f.name, .problem = .{ .missing_column = .{ .zig = zig } } });
        }
    }

    const expected = @tagName(S.primary_key);
    const pk = try queryStrings(conn, scratch, primary_key_sql, &.{ .{ .string = namespace }, .{ .string = table } });
    if (pk.items.len == 0) {
        try diag.add(.{ .table = table, .problem = .{ .no_primary_key = .{ .expected = expected } } });
    } else if (pk.items.len != 1 or !std.mem.eql(u8, pk.items[0], expected)) {
        const actual = try std.mem.join(diag.arena.allocator(), ", ", pk.items);
        try diag.add(.{ .table = table, .problem = .{ .wrong_primary_key = .{ .expected = expected, .actual = actual } } });
    }
}

fn find(columns: []const Column, name: []const u8) ?Column {
    for (columns) |c| if (std.mem.eql(u8, c.name, name)) return c;
    return null;
}

const Strings = struct {
    items: []const []const u8,
    fn first(s: Strings) ?[]const u8 {
        return if (s.items.len == 0) null else s.items[0];
    }
};

/// The first column of every row, copied into `scratch`.
fn queryStrings(conn: anytype, scratch: Allocator, sql: []const u8, params: []const gateway.Value) !Strings {
    const result = try gateway.run(conn, sql, params);
    defer result.deinit();
    errdefer result.drain() catch {};
    var out: std.ArrayList([]const u8) = .empty;
    while (try gateway.next(conn, result)) |row| {
        try out.append(scratch, try scratch.dupe(u8, try getText(conn, &row, 0)));
    }
    return .{ .items = out.items };
}

fn queryColumns(conn: anytype, scratch: Allocator, namespace: []const u8, table: []const u8) ![]const Column {
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
        });
    }
    return out.items;
}

fn getText(conn: anytype, row: anytype, col: usize) ![]const u8 {
    return row.get([]const u8, col) catch |err| gateway.mapError(conn, err);
}

// -- types --------------------------------------------------------------------

/// Whether a column of type `col` can hold field type `F` both ways:
/// zom-pg decodes it (see `decodeField` in gateway.zig) and it holds every
/// value of `F`. Nullability is checked apart from this.
fn accepts(comptime F: type, col: Column) bool {
    const T = switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
    // An enum is stored by tag name: text, or a Postgres ENUM.
    if (@typeInfo(T) == .@"enum" and col.is_enum) return true;
    inline for (comptime pgTypesFor(T)) |name| {
        if (std.mem.eql(u8, col.data_type, name)) return true;
    }
    return false;
}

/// The `information_schema.columns.data_type` names a column holding `T`
/// may have. Integers take the smallest Postgres integer that holds every
/// value of `T`, and any wider one; Postgres has nothing past `bigint`, so
/// a `u64` (or wider) is accepted in a `bigint` and range-checked per value.
pub fn pgTypesFor(comptime T: type) []const []const u8 {
    const text: []const []const u8 = &.{ "text", "character varying", "character" };
    return switch (@typeInfo(T)) {
        .int => |i| blk: {
            const signed_bits = if (i.signedness == .signed) i.bits else i.bits + 1;
            break :blk if (signed_bits <= 16)
                &.{ "smallint", "integer", "bigint" }
            else if (signed_bits <= 32)
                &.{ "integer", "bigint" }
            else
                &.{"bigint"};
        },
        .float => |f| if (f.bits <= 32)
            &.{ "real", "double precision", "numeric" }
        else
            &.{ "double precision", "numeric" },
        .bool => &.{"boolean"},
        // The Postgres ENUM case needs the catalog; see `accepts`.
        .@"enum" => text,
        .pointer => text,
        else => @compileError("zom-pg: unsupported attribute type " ++ @typeName(T)),
    };
}

test "pgTypesFor: integers need a column that holds every value" {
    const eq = std.testing.expectEqualDeep;
    try eq(@as([]const []const u8, &.{ "smallint", "integer", "bigint" }), pgTypesFor(u8));
    try eq(@as([]const []const u8, &.{ "smallint", "integer", "bigint" }), pgTypesFor(i16));
    try eq(@as([]const []const u8, &.{ "integer", "bigint" }), pgTypesFor(u16));
    try eq(@as([]const []const u8, &.{ "integer", "bigint" }), pgTypesFor(i32));
    try eq(@as([]const []const u8, &.{"bigint"}), pgTypesFor(u32));
    try eq(@as([]const []const u8, &.{"bigint"}), pgTypesFor(u64));
    try eq(@as([]const []const u8, &.{ "double precision", "numeric" }), pgTypesFor(f64));
    try eq(@as([]const []const u8, &.{"boolean"}), pgTypesFor(bool));
}

test "Mismatch formats as table.column: Zig vs pg" {
    var buf: [128]u8 = undefined;
    const m: Mismatch = .{ .table = "users", .column = "age", .problem = .{ .wrong_type = .{ .zig = "u8", .pg = "text" } } };
    try std.testing.expectEqualStrings("users.age: Zig u8 vs pg text", try std.fmt.bufPrint(&buf, "{f}", .{m}));
}
