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
const catalog = @import("catalog.zig");

const Allocator = std.mem.Allocator;
const Gateway = gateway.Gateway;
const log = std.log.scoped(.zom_pg);
const Column = catalog.Column;

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

    const namespaces = try catalog.queryStrings(conn, scratch, catalog.namespace_sql, &.{.{ .string = table }});
    if (namespaces.len == 0) return diag.add(.{ .table = table, .problem = .missing_table });
    const namespace = namespaces[0];

    const columns = try catalog.queryColumns(conn, scratch, namespace, table);
    inline for (fields) |f| {
        const zig = @typeName(f.type);
        const optional = @typeInfo(f.type) == .optional;
        if (catalog.findColumn(columns, f.name)) |col| {
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

    // A view (no primary key) has nothing to compare.
    if (!S.has_primary_key) return;
    const expected = @tagName(S.primary_key);
    const pk = try catalog.queryStrings(conn, scratch, catalog.primary_key_sql, &.{ .{ .string = namespace }, .{ .string = table } });
    if (pk.len == 0) {
        try diag.add(.{ .table = table, .problem = .{ .no_primary_key = .{ .expected = expected } } });
    } else if (pk.len != 1 or !std.mem.eql(u8, pk[0], expected)) {
        const actual = try std.mem.join(diag.arena.allocator(), ", ", pk);
        try diag.add(.{ .table = table, .problem = .{ .wrong_primary_key = .{ .expected = expected, .actual = actual } } });
    }
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

/// The Zig type `zom-pg-infer` gives a column of type `data_type` (an
/// `information_schema.columns.data_type` name), or null when zom-pg can't
/// decode it. The narrowest type `pgTypesFor` accepts in such a column.
/// Enums are `.@"enum"` with the type's name, filled in by `introspect`.
pub fn zigTypeFor(data_type: []const u8) ?ZigType {
    for (zig_types) |entry| {
        if (std.mem.eql(u8, entry[0], data_type)) return entry[1];
    }
    return null;
}

const zig_types = [_]struct { []const u8, ZigType }{
    .{ "smallint", .{ .int = .{ .signedness = .signed, .bits = 16 } } },
    .{ "integer", .{ .int = .{ .signedness = .signed, .bits = 32 } } },
    .{ "bigint", .{ .int = .{ .signedness = .signed, .bits = 64 } } },
    .{ "real", .{ .float = 32 } },
    .{ "double precision", .{ .float = 64 } },
    // Read as f64, so exact decimals are rounded.
    .{ "numeric", .{ .float = 64 } },
    .{ "boolean", .bool },
    .{ "text", .string },
    .{ "character varying", .string },
    .{ "character", .string },
};

const ZigType = @import("zom_sql").infer.Type;

test "zigTypeFor gives a type that pgTypesFor accepts back in the column" {
    inline for (zig_types) |entry| {
        const name = entry[0];
        const T = comptime switch (entry[1]) {
            .int => |i| @Int(i.signedness, i.bits),
            .float => |bits| if (bits == 32) f32 else f64,
            .bool => bool,
            .string => []const u8,
            .@"enum" => unreachable,
        };
        for (pgTypesFor(T)) |accepted| {
            if (std.mem.eql(u8, accepted, name)) break;
        } else return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(null, zigTypeFor("uuid"));
    try std.testing.expectEqual(null, zigTypeFor("timestamp with time zone"));
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
