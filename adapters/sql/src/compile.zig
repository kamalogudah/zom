//! The SELECT compiler: turns a relation's query into a parameterized
//! statement for one `Dialect`.
//!
//! Rendering goes through a `*std.Io.Writer`, so the compiler does not care
//! where the text ends up; `compileSelect` and friends render into an
//! allocating writer and hand back `Compiled`. Values are never written
//! into the SQL: each one is bound as a parameter, in the order its
//! placeholder appears.
//!
//! The SQL means what the memory adapter does (`Query.truth`), including
//! for null attributes; see `writeFilter` for the cases that need care.
//! Two differences remain, both from how a database stores and compares
//! things rather than from the SQL: an enum stored as text sorts by name
//! (memory and Postgres ENUMs sort in declaration order), and a `like`
//! pattern ending in a lone `\` is an error in Postgres, where memory
//! treats it as a literal `\`.

const std = @import("std");
const zom = @import("zom");
const Dialect = @import("dialect.zig").Dialect;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Value = zom.Value;
const Op = zom.Op;

pub const Compiled = struct {
    sql: []u8,
    /// One per placeholder, in order. String values borrow from the query.
    params: []Value,

    pub fn deinit(self: Compiled, allocator: Allocator) void {
        allocator.free(self.sql);
        allocator.free(self.params);
    }
};

/// What compiling can fail with.
pub const CompileError = Allocator.Error || error{
    /// `lt`, `lte`, `gt` or `gte` against `null`, which never matches.
    /// (`eq null` and `neq null` are `IS NULL` and `IS NOT NULL`.)
    InvalidNullComparison,
};

/// What rendering into a writer can fail with. Spelled out because
/// `writeNode` recurses, and a recursive function can't infer its error set.
pub const RenderError = CompileError || Writer.Error;

/// The bind parameters of a statement being rendered. `bind` appends a
/// value and writes its placeholder.
pub const Params = struct {
    list: std.ArrayList(Value) = .empty,
    allocator: Allocator,

    pub fn deinit(self: *Params) void {
        self.list.deinit(self.allocator);
    }

    pub fn bind(self: *Params, comptime dialect: Dialect, w: *Writer, v: Value) RenderError!void {
        try self.list.append(self.allocator, v);
        switch (dialect.placeholder) {
            .dollar_n => try w.print("${d}", .{self.list.items.len}),
            .question => try w.writeByte('?'),
        }
    }
};

/// Writes `name` as a quoted identifier: wrapped in `dialect.quote`, with
/// any quote inside doubled, so reserved words, mixed case and hostile
/// names stay one name.
pub fn writeIdent(comptime dialect: Dialect, w: *Writer, name: []const u8) Writer.Error!void {
    try w.writeByte(dialect.quote);
    var rest = name;
    while (std.mem.indexOfScalar(u8, rest, dialect.quote)) |i| {
        try w.writeAll(rest[0 .. i + 1]);
        try w.writeByte(dialect.quote);
        rest = rest[i + 1 ..];
    }
    try w.writeAll(rest);
    try w.writeByte(dialect.quote);
}

/// `SELECT` every field of `T` from `table`, filtered, ordered and paged
/// by `query`.
pub fn compileSelect(
    comptime dialect: Dialect,
    comptime T: type,
    allocator: Allocator,
    table: []const u8,
    query: zom.Query(T),
) CompileError!Compiled {
    return compileProjected(dialect, T, T, allocator, table, query);
}

/// `compileSelect` reading only the fields of `Out`, a struct whose fields
/// are all fields of `T`, such as `zom.Project(T, .{ .id, .name })`. The
/// query may still filter and order on fields `Out` leaves out.
pub fn compileProjected(
    comptime dialect: Dialect,
    comptime T: type,
    comptime Out: type,
    allocator: Allocator,
    table: []const u8,
    query: zom.Query(T),
) CompileError!Compiled {
    var out: Writer.Allocating = .init(allocator);
    defer out.deinit();
    var params: Params = .{ .allocator = allocator };
    defer params.deinit();

    writeSelect(dialect, T, Out, &out.writer, &params, table, &query) catch |err| switch (err) {
        // The allocating writer only fails when it can't grow.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };

    const sql = try out.toOwnedSlice();
    errdefer allocator.free(sql);
    return .{ .sql = sql, .params = try params.list.toOwnedSlice(allocator) };
}

/// `compileProjected` for a relation: its schema's dataset name is the
/// table, and its `Output` (the tuple, or what `select` narrowed it to)
/// the columns.
pub fn compileRelation(comptime dialect: Dialect, allocator: Allocator, relation: anytype) CompileError!Compiled {
    const R = @TypeOf(relation);
    return compileProjected(dialect, R.Tuple, R.Output, allocator, R.schema.name, relation.query);
}

/// Renders the whole statement into `w`, binding values into `params`.
pub fn writeSelect(
    comptime dialect: Dialect,
    comptime T: type,
    comptime Out: type,
    w: *Writer,
    params: *Params,
    table: []const u8,
    query: *const zom.Query(T),
) RenderError!void {
    const columns = comptime columnsOf(T, Out);

    try w.writeAll("SELECT ");
    inline for (columns, 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try writeIdent(dialect, w, name);
    }
    try w.writeAll(" FROM ");
    try writeIdent(dialect, w, table);

    var it = query.topNodes();
    var first = true;
    while (it.next()) |i| {
        try w.writeAll(if (first) " WHERE " else " AND ");
        first = false;
        try writeNode(dialect, T, w, params, query, @intCast(i));
    }

    for (query.orderSlice(), 0..) |o, i| {
        try w.writeAll(if (i == 0) " ORDER BY " else ", ");
        try writeOrder(dialect, T, w, o);
    }

    // LIMIT and OFFSET are bigint in Postgres and SQLite. A bound past that
    // can't be reached, so it is clamped rather than sent as an error.
    const max = std.math.maxInt(i64);
    if (query.limit) |l| {
        try w.print(" LIMIT {d}", .{@min(l, max)});
    } else if (query.offset > 0) {
        if (dialect.limit_all) |all| try w.print(" LIMIT {s}", .{all});
    }
    if (query.offset > 0) try w.print(" OFFSET {d}", .{@min(query.offset, max)});
}

/// The column names `Out` reads, each checked to be a field of `T`.
fn columnsOf(comptime T: type, comptime Out: type) []const []const u8 {
    const fields = @typeInfo(Out).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| {
        if (!@hasField(T, f.name))
            @compileError("zom_sql: '" ++ f.name ++ "' is not a field of " ++ @typeName(T));
        names[i] = f.name;
    }
    const final = names;
    return &final;
}

/// Renders `nodes[index]`: a filter, a parenthesized `AND` / `OR` group, or
/// `NOT (...)`.
fn writeNode(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    query: *const zom.Query(T),
    index: u8,
) RenderError!void {
    switch (query.nodes[index]) {
        .filter => |f| try writeFilter(dialect, T, w, params, query.filters[f]),
        .not => |child| {
            try w.writeAll("NOT ");
            // A group brings its own parentheses.
            const bare = query.nodes[child] == .filter or query.nodes[child] == .not;
            if (bare) try w.writeByte('(');
            try writeNode(dialect, T, w, params, query, child);
            if (bare) try w.writeByte(')');
        },
        .and_group, .or_group => |g| {
            const sep = if (query.nodes[index] == .and_group) " AND " else " OR ";
            try w.writeByte('(');
            for (g.first..g.first + g.len) |c| {
                if (c > g.first) try w.writeAll(sep);
                try writeNode(dialect, T, w, params, query, @intCast(c));
            }
            try w.writeByte(')');
        },
    }
}

/// `x <op> $n` and friends. Each is true, false or unknown exactly when
/// `Query.filterTruth` is, so wrapping it in `NOT` or `OR` keeps meaning
/// the same thing as in memory.
fn writeFilter(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    f: zom.Query(T).Filter,
) RenderError!void {
    const nullable = isOptional(T, f.field);
    switch (f.op) {
        .is_null, .is_not_null => {
            try writeIdent(dialect, w, @tagName(f.field));
            try w.writeAll(if (f.op == .is_null) " IS NULL" else " IS NOT NULL");
        },
        .eq, .neq, .lt, .lte, .gt, .gte => {
            // eq/neq null were stored as is_null/is_not_null.
            if (f.operand.one == .null) return error.InvalidNullComparison;
            try writeIdent(dialect, w, @tagName(f.field));
            try w.print(" {s} ", .{comparison(f.op)});
            try params.bind(dialect, w, f.operand.one);
        },
        .in, .not_in => {
            const list = f.operand.many;
            if (list.len == 0) {
                // `IN ()` is not valid SQL. An empty list matches no value
                // (`in`) or every value (`not_in`), and a null attribute is
                // unknown either way, as `NULL IN (...)` is.
                if (!nullable) return w.writeAll(if (f.op == .in) "1=0" else "1=1");
                try w.writeByte('(');
                try writeIdent(dialect, w, @tagName(f.field));
                try w.writeAll(if (f.op == .in) " IS NULL AND NULL)" else " IS NOT NULL OR NULL)");
                return;
            }
            try writeIdent(dialect, w, @tagName(f.field));
            try w.writeAll(if (f.op == .in) " IN (" else " NOT IN (");
            for (0..list.len) |i| {
                if (i > 0) try w.writeAll(", ");
                try params.bind(dialect, w, list.at(i));
            }
            try w.writeByte(')');
        },
        .like, .ilike => {
            if (f.op == .ilike and !dialect.ilike) {
                try w.writeAll("LOWER(");
                try writeIdent(dialect, w, @tagName(f.field));
                try w.writeAll(") LIKE LOWER(");
                try params.bind(dialect, w, f.operand.one);
                try w.writeByte(')');
            } else {
                try writeIdent(dialect, w, @tagName(f.field));
                try w.writeAll(if (f.op == .like) " LIKE " else " ILIKE ");
                try params.bind(dialect, w, f.operand.one);
            }
            // zom's patterns escape with `\`. Postgres defaults to it, but
            // SQLite has no default escape character, so always say so.
            try w.writeAll(" ESCAPE '\\'");
        },
        .between => {
            const lo, const hi = f.operand.range;
            try writeIdent(dialect, w, @tagName(f.field));
            try w.writeAll(" BETWEEN ");
            try params.bind(dialect, w, lo);
            try w.writeAll(" AND ");
            try params.bind(dialect, w, hi);
        },
    }
}

fn comparison(op: Op) []const u8 {
    return switch (op) {
        .eq => "=",
        .neq => "<>",
        .lt => "<",
        .lte => "<=",
        .gt => ">",
        .gte => ">=",
        else => unreachable,
    };
}

/// One sort key. Memory sorts nulls as if above every value (last on asc,
/// first on desc), which is Postgres's default but not SQLite's or
/// MySQL's, so a nullable key always says where its nulls go.
fn writeOrder(comptime dialect: Dialect, comptime T: type, w: *Writer, o: zom.Query(T).Order) Writer.Error!void {
    const dir = if (o.direction == .asc) " ASC" else " DESC";
    if (isOptional(T, o.field) and !dialect.nulls_order) {
        // `x IS NULL` is false for values and true for nulls, so sorting
        // on it in the key's own direction puts nulls where memory does.
        try writeIdent(dialect, w, @tagName(o.field));
        try w.print(" IS NULL{s}, ", .{dir});
    }
    try writeIdent(dialect, w, @tagName(o.field));
    try w.writeAll(dir);
    if (isOptional(T, o.field) and dialect.nulls_order)
        try w.writeAll(if (o.direction == .asc) " NULLS LAST" else " NULLS FIRST");
}

fn isOptional(comptime T: type, field: std.meta.FieldEnum(T)) bool {
    return switch (field) {
        inline else => |tag| @typeInfo(@FieldType(T, @tagName(tag))) == .optional,
    };
}
