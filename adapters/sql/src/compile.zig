//! The statement compiler: turns a relation's query into a parameterized
//! `SELECT`, and tuples, changes and queries into `INSERT`, `UPDATE` and
//! `DELETE`, for one `Dialect`.
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

/// What `compileUpdate` and `compileDelete` can fail with.
pub const WriteError = CompileError || error{
    /// An `UPDATE` or `DELETE` whose query has no filters, which would touch
    /// every row. This is a safety rule: a forgotten `where` must not empty
    /// or rewrite a table. Set `query.all = true` to mean it.
    UnboundedWrite,
    /// An `UPDATE` with no changes, which SQL can't express (`SET` needs at
    /// least one column). Nothing would change; a gateway can skip the
    /// statement, as `Update.commit` does.
    EmptyUpdate,
};

/// `WriteError` for the `write*` functions, which render into a writer.
pub const WriteRenderError = WriteError || Writer.Error;

/// The bind parameters of a statement being rendered. `bind` appends a
/// value and writes its placeholder.
pub const Params = struct {
    list: std.ArrayList(Value) = .empty,
    allocator: Allocator,

    pub fn deinit(self: *Params) void {
        self.list.deinit(self.allocator);
    }

    pub fn bind(self: *Params, comptime dialect: Dialect, w: *Writer, v: Value) (Allocator.Error || Writer.Error)!void {
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
    var b: Builder = .init(allocator);
    defer b.deinit();
    writeSelect(dialect, T, Out, &b.out.writer, &b.params, table, &query) catch |err| switch (err) {
        // The allocating writer only fails when it can't grow.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return b.finish();
}

/// A statement being rendered into memory: what each `compile*` function
/// hands to its `write*` function, then turns into a `Compiled`. Not moved
/// once rendering starts (the writer points into it).
const Builder = struct {
    out: Writer.Allocating,
    params: Params,

    fn init(allocator: Allocator) Builder {
        return .{ .out = .init(allocator), .params = .{ .allocator = allocator } };
    }

    fn deinit(self: *Builder) void {
        self.out.deinit();
        self.params.deinit();
    }

    fn finish(self: *Builder) Allocator.Error!Compiled {
        const allocator = self.params.allocator;
        const sql = try self.out.toOwnedSlice();
        errdefer allocator.free(sql);
        return .{ .sql = sql, .params = try self.params.list.toOwnedSlice(allocator) };
    }
};

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
    if (query.join) |*j| return writeJoinedSelect(dialect, T, Out, w, params, table, query, j);

    try w.writeAll("SELECT ");
    try writeColumns(dialect, w, null, comptime columnsOf(T, Out));
    try w.writeAll(" FROM ");
    try writeIdent(dialect, w, table);
    try writeWhere(dialect, T, w, params, null, query, null);
    try writeOrders(dialect, T, w, null, query);
    try writePaging(dialect, w, query);
}

/// A joined `SELECT` (`relation.join(.posts)`): each row of `table` with at
/// least one matching row of the joined table, once. Every column is
/// qualified with its table, since both tables may have an `id`:
///
///     SELECT DISTINCT "users"."id", ... FROM "users"
///     INNER JOIN "posts" ON "posts"."user_id" = "users"."id"
///     WHERE <the query's filters> AND <the whereJoined filters>
///     ORDER BY ... LIMIT ... OFFSET ...
///
/// `DISTINCT` removes the copies a parent gets from having several joined
/// rows, so it must see every column of `T` (the primary key among them):
/// over only a projection's columns it would also merge distinct parents
/// that happen to agree on them, which memory does not. So a projection
/// reads its columns from the joined rows in a derived table named after
/// `table`, and orders and pages outside it:
///
///     SELECT "users"."name" FROM (SELECT DISTINCT "users"."id", ... ) AS "users" ORDER BY ...
///
/// The same goes for a dialect without `NULLS LAST` that orders by a
/// nullable column, since its `x IS NULL` sort key is not in the select
/// list, which `DISTINCT` requires.
///
/// A table joined to itself is aliased by the association's name. Columns
/// whose types have no equality (`json`) can't go through `DISTINCT`.
fn writeJoinedSelect(
    comptime dialect: Dialect,
    comptime T: type,
    comptime Out: type,
    w: *Writer,
    params: *Params,
    table: []const u8,
    query: *const zom.Query(T),
    j: *const zom.Join,
) RenderError!void {
    const all = comptime columnsOf(T, T);
    // Outside `DISTINCT`, ORDER BY may use what the select list leaves out.
    const derived = Out != T or (!dialect.nulls_order and query.order_count > 0);
    if (derived) {
        try w.writeAll("SELECT ");
        try writeColumns(dialect, w, table, comptime columnsOf(T, Out));
        try w.writeAll(" FROM (");
    }
    const alias = joinAlias(table, j);
    try w.writeAll("SELECT DISTINCT ");
    try writeColumns(dialect, w, table, all);
    try w.writeAll(" FROM ");
    try writeIdent(dialect, w, table);
    try w.writeAll(" INNER JOIN ");
    try writeIdent(dialect, w, j.table);
    if (!std.mem.eql(u8, alias, j.table)) {
        try w.writeAll(" AS ");
        try writeIdent(dialect, w, alias);
    }
    try w.writeAll(" ON ");
    try writeColumn(dialect, w, alias, j.target_key);
    try w.writeAll(" = ");
    try writeColumn(dialect, w, table, j.source_key);
    try writeWhere(dialect, T, w, params, table, query, j);
    if (derived) {
        try w.writeAll(") AS ");
        try writeIdent(dialect, w, table);
    }
    try writeOrders(dialect, T, w, table, query);
    try writePaging(dialect, w, query);
}

/// What the joined table is called in a joined `SELECT`: its own name,
/// unless that is the parent's (a self-join), then the association's.
fn joinAlias(table: []const u8, j: *const zom.Join) []const u8 {
    if (!std.mem.eql(u8, j.table, table)) return j.table;
    if (!std.mem.eql(u8, j.assoc, table)) return j.assoc;
    return "zom_joined";
}

fn writeColumns(comptime dialect: Dialect, w: *Writer, qual: ?[]const u8, columns: []const []const u8) Writer.Error!void {
    for (columns, 0..) |name, i| {
        if (i > 0) try w.writeAll(", ");
        try writeColumn(dialect, w, qual, name);
    }
}

/// `"name"`, or `"qual"."name"`.
fn writeColumn(comptime dialect: Dialect, w: *Writer, qual: ?[]const u8, name: []const u8) Writer.Error!void {
    if (qual) |t| {
        try writeIdent(dialect, w, t);
        try w.writeByte('.');
    }
    try writeIdent(dialect, w, name);
}

fn writeOrders(comptime dialect: Dialect, comptime T: type, w: *Writer, qual: ?[]const u8, query: *const zom.Query(T)) Writer.Error!void {
    for (query.orderSlice(), 0..) |o, i| {
        try w.writeAll(if (i == 0) " ORDER BY " else ", ");
        try writeOrder(dialect, T, w, qual, o);
    }
}

fn writePaging(comptime dialect: Dialect, w: *Writer, query: anytype) Writer.Error!void {
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

/// ` WHERE a AND b ...` over the query's top-level nodes, then the joined
/// ones of `join`; nothing when there are none. Columns of the query's
/// tuple are qualified with `qual`, joined ones with the joined table.
fn writeWhere(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    qual: ?[]const u8,
    query: *const zom.Query(T),
    join: ?*const zom.Join,
) RenderError!void {
    var it = query.topNodes();
    var first = true;
    while (it.next()) |i| {
        try w.writeAll(if (first) " WHERE " else " AND ");
        first = false;
        try writeNode(dialect, T, w, params, qual, query, @intCast(i));
    }
    const j = join orelse return;
    const alias = joinAlias(qual.?, j);
    var joined = j.topNodes();
    while (joined.next()) |i| {
        try w.writeAll(if (first) " WHERE " else " AND ");
        first = false;
        try writeJoinNode(dialect, w, params, alias, j, @intCast(i));
    }
}

/// `writeNode` for a node of the join's filter tree, on the joined table.
fn writeJoinNode(
    comptime dialect: Dialect,
    w: *Writer,
    params: *Params,
    alias: []const u8,
    j: *const zom.Join,
    index: u8,
) RenderError!void {
    switch (j.nodes[index]) {
        .filter => |i| {
            const f = j.filters[i];
            try writeCondition(dialect, w, params, alias, f.column, f.nullable, f.op, f.operand);
        },
        .not => |child| {
            try w.writeAll("NOT ");
            const bare = j.nodes[child] == .filter or j.nodes[child] == .not;
            if (bare) try w.writeByte('(');
            try writeJoinNode(dialect, w, params, alias, j, child);
            if (bare) try w.writeByte(')');
        },
        .and_group, .or_group => |g| {
            const sep = if (j.nodes[index] == .and_group) " AND " else " OR ";
            try w.writeByte('(');
            for (g.first..g.first + g.len) |c| {
                if (c > g.first) try w.writeAll(sep);
                try writeJoinNode(dialect, w, params, alias, j, @intCast(c));
            }
            try w.writeByte(')');
        },
    }
}

// -- writes -----------------------------------------------------------------
//
// String params of a write statement borrow from what was passed in: the
// tuples for an insert, the changes and the query for an update.

/// The statements `compileInsertMany` returns, one per chunk of at most
/// `rowsPerStatement` rows, in the order of the rows. The caller owns them
/// and frees them all with `deinit`.
pub const Batch = struct {
    statements: []Compiled,

    pub fn deinit(self: Batch, allocator: Allocator) void {
        for (self.statements) |s| s.deinit(allocator);
        allocator.free(self.statements);
    }
};

/// How many tuples of `T` fit one `INSERT` under `dialect.max_params`, each
/// binding one parameter per field. A tuple too wide for a single row is a
/// compile error.
pub fn rowsPerStatement(comptime dialect: Dialect, comptime T: type) comptime_int {
    const fields = @typeInfo(T).@"struct".fields.len;
    if (fields == 0) @compileError("zom_sql: " ++ @typeName(T) ++ " has no fields to insert");
    const n = @divFloor(dialect.max_params, fields);
    if (n == 0) @compileError(std.fmt.comptimePrint(
        "zom_sql: {s} has {d} fields, more than the dialect's {d} bind parameters",
        .{ @typeName(T), fields, dialect.max_params },
    ));
    return n;
}

/// `INSERT INTO "table" ("a", ...) VALUES ($1, ...)` for every field of
/// `row`, then ` RETURNING *` when the dialect has it. Optional fields set
/// to null bind `.null`; enums bind their tag name.
pub fn compileInsert(
    comptime dialect: Dialect,
    comptime T: type,
    allocator: Allocator,
    table: []const u8,
    row: T,
) Allocator.Error!Compiled {
    return insertRows(dialect, T, allocator, table, (&row)[0..1]);
}

/// `compileInsert` for many tuples: one multi-row `INSERT ... VALUES (...),
/// (...)` per `rowsPerStatement(dialect, T)` tuples, so no statement carries
/// more than `dialect.max_params` parameters (65535 for Postgres). Each
/// statement numbers its placeholders from `$1`. A gateway runs them in
/// order, in one transaction if the batch must be all or nothing. No tuples
/// is no statements.
pub fn compileInsertMany(
    comptime dialect: Dialect,
    comptime T: type,
    allocator: Allocator,
    table: []const u8,
    rows: []const T,
) Allocator.Error!Batch {
    const per = comptime rowsPerStatement(dialect, T);
    const count = std.math.divCeil(usize, rows.len, per) catch unreachable;
    const statements = try allocator.alloc(Compiled, count);
    var done: usize = 0;
    errdefer {
        for (statements[0..done]) |s| s.deinit(allocator);
        allocator.free(statements);
    }
    while (done < count) : (done += 1) {
        const start = done * per;
        statements[done] = try insertRows(dialect, T, allocator, table, rows[start..@min(start + per, rows.len)]);
    }
    return .{ .statements = statements };
}

fn insertRows(comptime dialect: Dialect, comptime T: type, allocator: Allocator, table: []const u8, rows: []const T) Allocator.Error!Compiled {
    var b: Builder = .init(allocator);
    defer b.deinit();
    writeInsert(dialect, T, &b.out.writer, &b.params, table, rows) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return b.finish();
}

/// Renders one `INSERT` of `rows` into `w`. Asserts there is at least one
/// row and that they fit `dialect.max_params`; `compileInsertMany` splits a
/// longer slice.
pub fn writeInsert(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    table: []const u8,
    rows: []const T,
) (Allocator.Error || Writer.Error)!void {
    const fields = @typeInfo(T).@"struct".fields;
    std.debug.assert(rows.len > 0 and rows.len <= rowsPerStatement(dialect, T));

    try w.writeAll("INSERT INTO ");
    try writeIdent(dialect, w, table);
    try w.writeAll(" (");
    inline for (fields, 0..) |f, i| {
        if (i > 0) try w.writeAll(", ");
        try writeIdent(dialect, w, f.name);
    }
    try w.writeAll(") VALUES ");
    for (rows, 0..) |row, r| {
        if (r > 0) try w.writeAll(", ");
        try w.writeByte('(');
        inline for (fields, 0..) |f, i| {
            if (i > 0) try w.writeAll(", ");
            try params.bind(dialect, w, zom.query.toValue(@field(row, f.name)));
        }
        try w.writeByte(')');
    }
    if (dialect.returning) try w.writeAll(" RETURNING *");
}

/// `UPDATE "table" SET "a" = $1, ... WHERE ...`. Placeholders run on from
/// `SET` into `WHERE`. Only the query's filters are used: like the memory
/// adapter, an update ignores `order`, `limit` and `offset`. A field set
/// more than once takes its last value, as in memory, since SQL rejects a
/// column assigned twice. See `WriteError` for the unfiltered and empty
/// cases.
pub fn compileUpdate(
    comptime dialect: Dialect,
    comptime T: type,
    allocator: Allocator,
    table: []const u8,
    query: zom.Query(T),
    changes: []const zom.Query(T).Change,
) WriteError!Compiled {
    var b: Builder = .init(allocator);
    defer b.deinit();
    writeUpdate(dialect, T, &b.out.writer, &b.params, table, &query, changes) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return b.finish();
}

/// `DELETE FROM "table" WHERE ...`. Like `compileUpdate`, only the filters
/// are used, and a query without any is `error.UnboundedWrite` unless
/// `query.all` is set.
pub fn compileDelete(
    comptime dialect: Dialect,
    comptime T: type,
    allocator: Allocator,
    table: []const u8,
    query: zom.Query(T),
) WriteError!Compiled {
    var b: Builder = .init(allocator);
    defer b.deinit();
    writeDelete(dialect, T, &b.out.writer, &b.params, table, &query) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    return b.finish();
}

/// Renders `compileUpdate`'s statement into `w`. The checks run before
/// anything is written.
pub fn writeUpdate(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    table: []const u8,
    query: *const zom.Query(T),
    changes: []const zom.Query(T).Change,
) WriteRenderError!void {
    if (changes.len == 0) return error.EmptyUpdate;
    try checkBounded(T, query);

    try w.writeAll("UPDATE ");
    try writeIdent(dialect, w, table);
    var first = true;
    for (changes, 0..) |c, i| {
        if (setLater(T, changes[i + 1 ..], c.field)) continue;
        try w.writeAll(if (first) " SET " else ", ");
        first = false;
        try writeIdent(dialect, w, @tagName(c.field));
        try w.writeAll(" = ");
        try params.bind(dialect, w, c.value);
    }
    try writeWriteWhere(dialect, T, w, params, table, query);
}

/// Renders `compileDelete`'s statement into `w`.
pub fn writeDelete(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    table: []const u8,
    query: *const zom.Query(T),
) WriteRenderError!void {
    try checkBounded(T, query);
    try w.writeAll("DELETE FROM ");
    try writeIdent(dialect, w, table);
    try writeWriteWhere(dialect, T, w, params, table, query);
}

/// A joined write keeps a source row only when one joined row passes every
/// joined filter. The correlated subquery also handles joins with no filters.
fn writeWriteWhere(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    table: []const u8,
    query: *const zom.Query(T),
) RenderError!void {
    try writeWhere(dialect, T, w, params, if (query.join == null) null else table, query, null);
    const j = if (query.join) |*join| join else return;
    var own = query.topNodes();
    try w.writeAll(if (own.next() == null) " WHERE EXISTS (SELECT 1 FROM " else " AND EXISTS (SELECT 1 FROM ");
    const alias = joinAlias(table, j);
    try writeIdent(dialect, w, j.table);
    if (!std.mem.eql(u8, alias, j.table)) {
        try w.writeAll(" AS ");
        try writeIdent(dialect, w, alias);
    }
    try w.writeAll(" WHERE ");
    try writeColumn(dialect, w, alias, j.target_key);
    try w.writeAll(" = ");
    try writeColumn(dialect, w, table, j.source_key);
    var joined = j.topNodes();
    while (joined.next()) |i| {
        try w.writeAll(" AND ");
        try writeJoinNode(dialect, w, params, alias, j, @intCast(i));
    }
    try w.writeByte(')');
}

/// A join itself bounds a write; without one, require a source filter or all.
fn checkBounded(comptime T: type, query: *const zom.Query(T)) error{UnboundedWrite}!void {
    var it = query.topNodes();
    if (it.next() == null and query.join == null and !query.all) return error.UnboundedWrite;
}

fn setLater(comptime T: type, rest: []const zom.Query(T).Change, field: zom.Query(T).Field) bool {
    for (rest) |c| if (c.field == field) return true;
    return false;
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
    qual: ?[]const u8,
    query: *const zom.Query(T),
    index: u8,
) RenderError!void {
    switch (query.nodes[index]) {
        .filter => |f| try writeFilter(dialect, T, w, params, qual, query.filters[f]),
        .not => |child| {
            try w.writeAll("NOT ");
            // A group brings its own parentheses.
            const bare = query.nodes[child] == .filter or query.nodes[child] == .not;
            if (bare) try w.writeByte('(');
            try writeNode(dialect, T, w, params, qual, query, child);
            if (bare) try w.writeByte(')');
        },
        .and_group, .or_group => |g| {
            const sep = if (query.nodes[index] == .and_group) " AND " else " OR ";
            try w.writeByte('(');
            for (g.first..g.first + g.len) |c| {
                if (c > g.first) try w.writeAll(sep);
                try writeNode(dialect, T, w, params, qual, query, @intCast(c));
            }
            try w.writeByte(')');
        },
    }
}

/// One filter of the query's tuple; see `writeCondition`.
fn writeFilter(
    comptime dialect: Dialect,
    comptime T: type,
    w: *Writer,
    params: *Params,
    qual: ?[]const u8,
    f: zom.Query(T).Filter,
) RenderError!void {
    try writeCondition(dialect, w, params, qual, @tagName(f.field), isOptional(T, f.field), f.op, f.operand);
}

/// `x <op> $n` and friends, on column `column` (qualified with `qual`),
/// which is nullable when its field is optional. Each is true, false or
/// unknown exactly when `Query.filterTruth` is, so wrapping it in `NOT` or
/// `OR` keeps meaning the same thing as in memory. Untyped, so the joined
/// filters, which only have their column's name, render the same way.
fn writeCondition(
    comptime dialect: Dialect,
    w: *Writer,
    params: *Params,
    qual: ?[]const u8,
    column: []const u8,
    nullable: bool,
    op: Op,
    operand: zom.query.Operand,
) RenderError!void {
    switch (op) {
        .is_null, .is_not_null => {
            try writeColumn(dialect, w, qual, column);
            try w.writeAll(if (op == .is_null) " IS NULL" else " IS NOT NULL");
        },
        .eq, .neq, .lt, .lte, .gt, .gte => {
            // eq/neq null were stored as is_null/is_not_null.
            if (operand.one == .null) return error.InvalidNullComparison;
            try writeColumn(dialect, w, qual, column);
            try w.print(" {s} ", .{comparison(op)});
            try params.bind(dialect, w, operand.one);
        },
        .in, .not_in => {
            const list = operand.many;
            if (list.len == 0) {
                // `IN ()` is not valid SQL. An empty list matches no value
                // (`in`) or every value (`not_in`), and a null attribute is
                // unknown either way, as `NULL IN (...)` is.
                if (!nullable) return w.writeAll(if (op == .in) "1=0" else "1=1");
                try w.writeByte('(');
                try writeColumn(dialect, w, qual, column);
                try w.writeAll(if (op == .in) " IS NULL AND NULL)" else " IS NOT NULL OR NULL)");
                return;
            }
            try writeColumn(dialect, w, qual, column);
            try w.writeAll(if (op == .in) " IN (" else " NOT IN (");
            for (0..list.len) |i| {
                if (i > 0) try w.writeAll(", ");
                try params.bind(dialect, w, list.at(i));
            }
            try w.writeByte(')');
        },
        .like, .ilike => {
            if (op == .ilike and !dialect.ilike) {
                try w.writeAll("LOWER(");
                try writeColumn(dialect, w, qual, column);
                try w.writeAll(") LIKE LOWER(");
                try params.bind(dialect, w, operand.one);
                try w.writeByte(')');
            } else {
                try writeColumn(dialect, w, qual, column);
                try w.writeAll(if (op == .like) " LIKE " else " ILIKE ");
                try params.bind(dialect, w, operand.one);
            }
            // zom's patterns escape with `\`. Postgres defaults to it, but
            // SQLite has no default escape character, so always say so.
            try w.writeAll(" ESCAPE '\\'");
        },
        .between => {
            const lo, const hi = operand.range;
            try writeColumn(dialect, w, qual, column);
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
fn writeOrder(comptime dialect: Dialect, comptime T: type, w: *Writer, qual: ?[]const u8, o: zom.Query(T).Order) Writer.Error!void {
    const dir = if (o.direction == .asc) " ASC" else " DESC";
    if (isOptional(T, o.field) and !dialect.nulls_order) {
        // `x IS NULL` is false for values and true for nulls, so sorting
        // on it in the key's own direction puts nulls where memory does.
        try writeColumn(dialect, w, qual, @tagName(o.field));
        try w.print(" IS NULL{s}, ", .{dir});
    }
    try writeColumn(dialect, w, qual, @tagName(o.field));
    try w.writeAll(dir);
    if (isOptional(T, o.field) and dialect.nulls_order)
        try w.writeAll(if (o.direction == .asc) " NULLS LAST" else " NULLS FIRST");
}

fn isOptional(comptime T: type, field: std.meta.FieldEnum(T)) bool {
    return switch (field) {
        inline else => |tag| @typeInfo(@FieldType(T, @tagName(tag))) == .optional,
    };
}
