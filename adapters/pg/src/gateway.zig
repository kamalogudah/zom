//! The Postgres gateway: a `pg.Pool`, and one dataset per schema whose
//! statements come from zom-sql.
//!
//! Every read compiles the relation's query with `zom_sql` for the
//! `.postgres` dialect, binds its `zom.Value` params through `pg.Stmt`, and
//! decodes each row into the tuple by column name.
//!
//! String ownership (`strings = .caller`): pg.zig's row data is only valid
//! until the next row or the end of the result, so every string a dataset
//! returns, from `read`, `readProjected` or `insert`, is copied into the
//! allocator passed to that call, and belongs to the caller. Free reads with
//! the relation's `free(allocator, rows)` and single tuples with
//! `freeOne(allocator, tuple)`, or read into an arena.
//!
//! Transactions: `transaction(ctx, f)` pins one pooled connection and hands
//! `f` a gateway (`*Gateway`, the same type) whose datasets all run on it.
//! A nested `transaction` on that gateway is a SAVEPOINT. See `Source`.

const std = @import("std");
const zom = @import("zom");
const zom_sql = @import("zom_sql");
const pg = @import("pg");
const verify_mod = @import("verify.zig");

const Allocator = std.mem.Allocator;
pub const Value = zom.Value;
const log = std.log.scoped(.zom_pg);
const dialect = zom_sql.Dialect.postgres;

pub const Gateway = struct {
    pub const adapter_name = "postgres";

    /// Where to connect. Either `url` (`postgres://user:pass@host:port/db`,
    /// parsed by pg.zig, with `?sslmode=require` and the like) or the
    /// separate fields, which `url` overrides when set.
    pub const Config = struct {
        /// pg.zig does its socket I/O through `std.Io`.
        io: std.Io,
        url: ?[]const u8 = null,
        host: []const u8 = "127.0.0.1",
        port: u16 = 5432,
        user: []const u8 = "postgres",
        password: ?[]const u8 = null,
        database: ?[]const u8 = null,
        /// Most connections open at once. All are opened by `init`.
        pool_size: u16 = 4,
        /// Milliseconds to wait for a free connection before
        /// `error.ConnectionFailed`.
        acquire_timeout_ms: u32 = 10_000,
    };

    allocator: Allocator,
    /// The pool, or inside `transaction` the connection it pinned.
    source: Source,
    /// One per schema, made by the first `dataset(S)` call.
    datasets: std.ArrayList(Entry) = .empty,

    /// What every zom-pg call can fail with, besides its own checks
    /// (`error.MissingColumn` and the like). The first five are zom's
    /// shared names (`zom.Error`).
    pub const Error = error{
        /// Any unique violation (SQLSTATE `23505`), on the primary key or
        /// on another UNIQUE constraint: `lastError().constraint` says which.
        DuplicatePrimaryKey,
        /// `22003`, or a parameter pg.zig can't fit in its column.
        ValueOutOfRange,
        /// `42P01`: the schema's table does not exist.
        NotFound,
        /// `25006`: a read-only transaction or a replica.
        ReadOnly,
        /// No connection in time, a socket error, or SQLSTATE class `08`.
        ConnectionFailed,
        /// Any other Postgres or pg.zig error. `lastError()` has the server's.
        Database,
        OutOfMemory,
        /// `std.Io` cancelled the call.
        Canceled,
    };

    /// The Postgres error a call on this thread last got, or null if there
    /// has been none. The strings live in a per-thread buffer (long ones
    /// are cut short), valid until the next Postgres error on this thread.
    /// A call that succeeds leaves it as it was, like `errno`.
    pub fn lastError() ?ServerError {
        return last_error.err;
    }

    const Entry = struct {
        type_name: []const u8,
        ptr: *anyopaque,
        destroy: *const fn (*anyopaque, Allocator) void,
    };

    /// Opens the pool. `error.ConnectionFailed` when Postgres can't be
    /// reached or refuses the credentials.
    pub fn init(allocator: Allocator, config: Config) !Gateway {
        const pool = openPool(allocator, config) catch |err| {
            log.debug("opening the pool failed: {t}", .{err});
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.InvalidUriScheme, error.UnsupportedConnectionParam, error.UnsupportedSSLModeValue, error.InvalidFormat, error.UnexpectedCharacter, error.InvalidPort => error.InvalidUrl,
                else => error.ConnectionFailed,
            };
        };
        return .{ .allocator = allocator, .source = .{ .pool = pool } };
    }

    fn openPool(allocator: Allocator, config: Config) !*pg.Pool {
        const opts: pg.Pool.Opts = .{
            .size = config.pool_size,
            .timeout = config.acquire_timeout_ms,
            .connect = .{ .host = config.host, .port = config.port },
            .auth = .{ .username = config.user, .password = config.password, .database = config.database },
        };
        if (config.url) |url| return pg.Pool.initUri(config.io, allocator, try std.Uri.parse(url), opts);
        return pg.Pool.init(config.io, allocator, opts);
    }

    /// Closes the pool. Not for the gateway `transaction` passes to its
    /// callback, which `transaction` cleans up itself.
    pub fn deinit(self: *Gateway) void {
        for (self.datasets.items) |e| e.destroy(e.ptr, self.allocator);
        self.datasets.deinit(self.allocator);
        if (self.source == .pool) self.source.pool.deinit();
        self.* = undefined;
    }

    pub fn Dataset(comptime S: type) type {
        return PgDataset(S);
    }

    /// The dataset for `S`, on the table named `S.name`. The pointer stays
    /// valid until `deinit`.
    pub fn dataset(self: *Gateway, comptime S: type) !*Dataset(S) {
        const D = Dataset(S);
        const name = @typeName(S);
        for (self.datasets.items) |e| {
            if (std.mem.eql(u8, e.type_name, name)) return @ptrCast(@alignCast(e.ptr));
        }
        try self.datasets.ensureUnusedCapacity(self.allocator, 1);
        const d = try self.allocator.create(D);
        d.* = .{ .source = self.source, .allocator = self.allocator };
        self.datasets.appendAssumeCapacity(.{ .type_name = name, .ptr = d, .destroy = D.destroy });
        return d;
    }

    /// Checks the table `S.name` against `S` at startup: every field of
    /// `S.Tuple` has a column of a type that holds it (see `pgTypesFor`
    /// in verify.zig), optional fields are on nullable columns and the
    /// others on `NOT NULL` ones, and the primary key is
    /// `S.primary_key` alone. Columns the struct doesn't have are allowed.
    ///
    /// Every mismatch is reported at once: appended to `diagnostics`, or
    /// logged at error level (scope `.zom_pg`) when it is null, and the
    /// call returns `error.SchemaMismatch`. A missing table is one
    /// mismatch (`.missing_table`), not `error.NotFound`.
    pub fn verify(self: *Gateway, comptime S: type, diagnostics: ?*Diagnostics) !void {
        return verify_mod.verify(self, S, diagnostics);
    }

    pub const Diagnostics = verify_mod.Diagnostics;
    pub const Mismatch = verify_mod.Mismatch;

    /// The base tables of `schema` and the enums they use, as a
    /// `zom_sql.infer.Catalog`: what `zom-pg-infer` renders into schema
    /// structs. Free it with `deinit`. `error.SchemaNotFound` when there
    /// is no such schema. See introspect.zig.
    pub fn introspect(self: *Gateway, allocator: Allocator, schema: []const u8) !Introspection {
        return @import("introspect.zig").introspect(self, allocator, schema);
    }

    pub const Introspection = @import("introspect.zig").Introspection;

    /// Runs `sql` with no parameters and no rows, e.g. `CREATE TABLE`. zom
    /// has no migrations; this is for setup and tests.
    pub fn exec(self: *Gateway, sql: []const u8) Error!void {
        const conn = try self.source.acquire();
        defer self.source.release(conn);
        _ = conn.exec(sql, .{}) catch |err| return mapError(conn, err);
    }

    /// `f(ctx, tx)` in a transaction: BEGIN, then COMMIT when `f` returns,
    /// or ROLLBACK when it (or the COMMIT) fails, returning `f`'s error
    /// unchanged. Zig has no closures, so `f`'s state comes in through
    /// `ctx`. Returns what `f` returns.
    ///
    /// `tx` is a `*Gateway` pinned to one pooled connection: every dataset
    /// made from it, and so every relation over it, runs on that
    /// connection. It lives until `transaction` returns, and so do its
    /// datasets; don't `deinit` it or keep relations over it. It is for one
    /// thread. Calls on the outer gateway inside `f` are not part of the
    /// transaction, and wait for a second connection.
    ///
    /// On `tx`, `transaction` nests as a SAVEPOINT: its errors roll back
    /// to the savepoint only. That is also how to go on after an error
    /// inside `f`: Postgres aborts the whole transaction on any failed
    /// statement, so catching the error and carrying on fails every later
    /// call (`error.Database`), and COMMIT with it. Run the statement that
    /// may fail in a nested `transaction` and catch that instead.
    pub fn transaction(self: *Gateway, ctx: anytype, comptime f: anytype) Transaction(@TypeOf(ctx), f) {
        const conn = try self.source.acquire();
        defer self.source.release(conn);
        const depth = self.source.nextDepth();

        var tx: Gateway = .{ .allocator = self.allocator, .source = .{ .tx = .{ .conn = conn, .depth = depth } } };
        defer tx.deinit();

        try begin(conn, depth);
        // An error rolling back can't replace the one that caused it.
        errdefer rollback(conn, depth);
        const out = if (comptime isErrorUnion(FnResult(@TypeOf(ctx), f))) try f(ctx, &tx) else f(ctx, &tx);
        try commit(conn, depth);
        return out;
    }

    /// What `transaction(ctx, f)` returns: `f`'s result, with
    /// `Gateway.Error` merged into its error set.
    pub fn Transaction(comptime Ctx: type, comptime f: anytype) type {
        const R = FnResult(Ctx, f);
        return switch (@typeInfo(R)) {
            .error_union => |eu| (eu.error_set || Error)!eu.payload,
            else => Error!R,
        };
    }

    /// `@TypeOf(f(ctx, tx))`, which also works when `f` is generic (its
    /// `@typeInfo` return type is then null).
    fn FnResult(comptime Ctx: type, comptime f: anytype) type {
        return @TypeOf(f(@as(Ctx, undefined), @as(*Gateway, undefined)));
    }
};

fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

/// Where a gateway's calls get their connection. The value is copied into
/// each dataset, so a gateway may move after `dataset` is called.
const Source = union(enum) {
    /// Each call takes a connection and gives it back.
    pool: *pg.Pool,
    /// Inside `transaction`: every call uses `conn`. `depth` is 0 for the
    /// outermost transaction and n for the n-th SAVEPOINT inside it.
    tx: struct { conn: *pg.Conn, depth: u32 },

    pub fn acquire(self: Source) Gateway.Error!*pg.Conn {
        return switch (self) {
            .pool => |pool| pool.acquire() catch |err| {
                log.debug("acquiring a connection failed: {t}", .{err});
                return switch (@as(anyerror, err)) {
                    error.OutOfMemory => error.OutOfMemory,
                    error.Canceled => error.Canceled,
                    else => error.ConnectionFailed,
                };
            },
            .tx => |t| t.conn,
        };
    }

    pub fn release(self: Source, conn: *pg.Conn) void {
        // A connection that isn't idle (an error mid-result, a transaction
        // left open) is closed and replaced by the pool.
        if (self == .pool) self.pool.release(conn);
    }

    /// The depth a transaction started now would have.
    fn nextDepth(self: Source) u32 {
        return switch (self) {
            .pool => 0,
            .tx => |t| t.depth + 1,
        };
    }
};

// -- transactions ------------------------------------------------------------

/// "zom_<depth>", the savepoint for a transaction nested `depth` deep.
fn savepointSql(buf: []u8, comptime fmt: []const u8, depth: u32) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{ .d = depth }) catch unreachable;
}

fn begin(conn: *pg.Conn, depth: u32) Gateway.Error!void {
    var buf: [64]u8 = undefined;
    if (depth == 0) {
        conn.begin() catch |err| return mapError(conn, err);
    } else {
        _ = conn.exec(savepointSql(&buf, "SAVEPOINT zom_{[d]d}", depth), .{}) catch |err| return mapError(conn, err);
    }
}

/// COMMIT, or RELEASE the savepoint. On a transaction a swallowed error
/// aborted, this is `error.Database`: pg.zig refuses the COMMIT itself,
/// and Postgres a RELEASE (`25P02`, in_failed_sql_transaction).
fn commit(conn: *pg.Conn, depth: u32) Gateway.Error!void {
    var buf: [64]u8 = undefined;
    if (depth == 0) {
        conn.commit() catch |err| return mapError(conn, err);
    } else {
        _ = conn.exec(savepointSql(&buf, "RELEASE SAVEPOINT zom_{[d]d}", depth), .{}) catch |err| return mapError(conn, err);
    }
}

/// ROLLBACK, or roll back to the savepoint and drop it, which leaves the
/// outer transaction usable. Sent even on a connection in the failed
/// state. Errors are dropped: the caller is already returning one.
fn rollback(conn: *pg.Conn, depth: u32) void {
    var buf: [96]u8 = undefined;
    if (depth == 0) {
        conn.rollback() catch |err| log.debug("ROLLBACK failed: {t}", .{err});
    } else {
        const sql = savepointSql(&buf, "ROLLBACK TO SAVEPOINT zom_{[d]d}; RELEASE SAVEPOINT zom_{[d]d}", depth);
        conn.execIgnoringState(sql) catch |err| log.debug("{s} failed: {t}", .{ sql, err });
    }
}

fn PgDataset(comptime S: type) type {
    return struct {
        const Self = @This();
        const T = S.Tuple;
        const Q = zom.Query(T);
        const table = S.name;

        /// Everything zom-sql renders, joins included.
        pub const supports: zom.Supports = .all;
        /// See the top of this file.
        pub const strings: zom.StringOwnership = .caller;

        /// The gateway's pool, or its transaction's connection.
        source: Source,
        /// For statements, which are freed before each call returns.
        allocator: Allocator,

        fn destroy(ptr: *anyopaque, allocator: Allocator) void {
            allocator.destroy(@as(*Self, @ptrCast(@alignCast(ptr))));
        }

        /// The matching tuples. The slice and every string in it belong to
        /// `allocator`.
        pub fn read(self: *Self, query: Q, allocator: Allocator) ![]T {
            return self.readProjected(query, T, allocator);
        }

        /// `read`, selecting only the fields of `P`.
        pub fn readProjected(self: *Self, query: Q, comptime P: type, allocator: Allocator) ![]P {
            const compiled = zom_sql.compileProjected(dialect, T, P, allocator, table, query) catch |err| switch (err) {
                error.InvalidNullComparison => return emptyOrNull(P, query, allocator),
                else => |e| return e,
            };
            defer compiled.deinit(allocator);

            const conn = try self.source.acquire();
            defer self.source.release(conn);
            const result = try run(conn, compiled.sql, compiled.params);
            defer result.deinit();
            errdefer result.drain() catch {};

            var rows: std.ArrayList(P) = .empty;
            errdefer {
                for (rows.items) |r| zom.strings.freeFields(P, allocator, r, &.{});
                rows.deinit(allocator);
            }
            const columns = try columnMap(P, result);
            while (try next(conn, result)) |row| {
                try rows.ensureUnusedCapacity(allocator, 1);
                rows.appendAssumeCapacity(try decodeRow(P, &row, &columns, allocator));
            }
            return rows.toOwnedSlice(allocator);
        }

        pub fn count(self: *Self, query: Q) !usize {
            const a = self.allocator;
            const compiled = zom_sql.compileSelect(dialect, T, a, table, query) catch |err| switch (err) {
                error.InvalidNullComparison => return if (query.isConjunction()) 0 else err,
                else => |e| return e,
            };
            defer compiled.deinit(a);
            // Counting the SELECT keeps its limit and offset.
            const sql = try std.fmt.allocPrint(a, "SELECT COUNT(*) FROM ({s}) AS \"zom_count\"", .{compiled.sql});
            defer a.free(sql);

            const conn = try self.source.acquire();
            defer self.source.release(conn);
            const result = try run(conn, sql, compiled.params);
            defer result.deinit();
            errdefer result.drain() catch {};
            const row = (try next(conn, result)) orelse return error.UnexpectedResult;
            const n = row.get(i64, 0) catch |err| return mapError(conn, err);
            try drainRest(conn, result);
            return std.math.cast(usize, n) orelse error.UnexpectedResult;
        }

        /// `INSERT ... RETURNING *`: the stored tuple, as Postgres has it.
        /// Its strings belong to `allocator`. `error.DuplicatePrimaryKey`
        /// on a unique violation.
        pub fn insert(self: *Self, row: T, allocator: Allocator) !T {
            const a = self.allocator;
            const compiled = try zom_sql.compileInsert(dialect, T, a, table, row);
            defer compiled.deinit(a);

            const conn = try self.source.acquire();
            defer self.source.release(conn);
            const result = try run(conn, compiled.sql, compiled.params);
            defer result.deinit();
            errdefer result.drain() catch {};
            const columns = try columnMap(T, result);
            const r = (try next(conn, result)) orelse return error.UnexpectedResult;
            const stored = try decodeRow(T, &r, &columns, allocator);
            errdefer zom.strings.freeFields(T, allocator, stored, &.{});
            try drainRest(conn, result);
            return stored;
        }

        /// All or nothing: the multi-row `INSERT`s zom-sql splits the batch
        /// into run in one transaction, or inside `transaction` in a
        /// SAVEPOINT, so a failed batch leaves the transaction usable.
        pub fn insertMany(self: *Self, rows: []const T) !usize {
            if (rows.len == 0) return 0;
            const a = self.allocator;
            const batch = try zom_sql.compileInsertMany(dialect, T, a, table, rows);
            defer batch.deinit(a);

            const conn = try self.source.acquire();
            defer self.source.release(conn);
            const depth = self.source.nextDepth();
            try begin(conn, depth);
            errdefer rollback(conn, depth);
            var n: usize = 0;
            for (batch.statements) |s| n += try runCounting(conn, s.sql, s.params);
            try commit(conn, depth);
            return n;
        }

        /// The number of rows changed. A change whose value does not fit
        /// the attribute's Zig type is `error.ValueOutOfRange`, even when
        /// the column would take it (a `u8` attribute in a `smallint`).
        pub fn update(self: *Self, query: Q, changes: []const Q.Change) !usize {
            for (changes) |c| try checkFits(c);
            var everything = query;
            // A relation with no filters means every row, as in memory.
            everything.all = true;
            const a = self.allocator;
            const compiled = zom_sql.compileUpdate(dialect, T, a, table, everything, changes) catch |err| switch (err) {
                error.EmptyUpdate => return 0,
                error.InvalidNullComparison => return if (query.isConjunction()) 0 else err,
                else => |e| return e,
            };
            defer compiled.deinit(a);
            return self.runWrite(compiled);
        }

        /// The number of rows deleted. No filters deletes every row.
        pub fn delete(self: *Self, query: Q) !usize {
            var everything = query;
            everything.all = true;
            const a = self.allocator;
            const compiled = zom_sql.compileDelete(dialect, T, a, table, everything) catch |err| switch (err) {
                error.InvalidNullComparison => return if (query.isConjunction()) 0 else err,
                else => |e| return e,
            };
            defer compiled.deinit(a);
            return self.runWrite(compiled);
        }

        /// pg.zig's `Result` does not report the affected count, so writes
        /// return a row per affected row and count those.
        fn runWrite(self: *Self, compiled: zom_sql.Compiled) !usize {
            const a = self.allocator;
            const sql = try std.fmt.allocPrint(a, "{s} RETURNING 1", .{compiled.sql});
            defer a.free(sql);
            const conn = try self.source.acquire();
            defer self.source.release(conn);
            return runCounting(conn, sql, compiled.params);
        }

        fn checkFits(c: Q.Change) !void {
            switch (c.field) {
                inline else => |f| {
                    const F = @FieldType(T, @tagName(f));
                    _ = try zom.query.fromValue(F, c.value);
                },
            }
        }

        /// A query zom-sql refused for comparing with null (`lt null`
        /// and friends), which matches nothing when it is a plain AND of
        /// filters. Inside an `or` / `not` group it is still an error.
        fn emptyOrNull(comptime P: type, query: Q, allocator: Allocator) ![]P {
            if (!query.isConjunction()) return error.InvalidNullComparison;
            return allocator.alloc(P, 0);
        }
    };
}

// -- statements --------------------------------------------------------------

/// Prepares `sql`, binds `params` and executes it. The caller deinits the
/// result (and drains it if it stops reading early).
pub fn run(conn: *pg.Conn, sql: []const u8, params: []const Value) !*pg.Result {
    var stmt = pg.Stmt.init(conn, .{ .column_names = true }) catch |err| return mapError(conn, err);
    errdefer stmt.deinit();
    stmt.prepare(sql, null) catch |err| return mapError(conn, err);
    if (stmt.param_count != params.len) return error.WrongNumberOfParameters;
    for (params) |p| bindValue(&stmt, p) catch |err| return mapError(conn, err);
    return stmt.execute() catch |err| return mapError(conn, err);
}

/// Runs `sql` and returns how many rows it returned.
fn runCounting(conn: *pg.Conn, sql: []const u8, params: []const Value) !usize {
    const result = try run(conn, sql, params);
    defer result.deinit();
    errdefer result.drain() catch {};
    var n: usize = 0;
    while (try next(conn, result)) |_| n += 1;
    return n;
}

pub fn next(conn: *pg.Conn, result: *pg.Result) !?pg.Row {
    return result.next() catch |err| mapError(conn, err);
}

fn drainRest(conn: *pg.Conn, result: *pg.Result) !void {
    while (try next(conn, result)) |_| {}
}

/// One `zom.Value` as a parameter. Postgres has told pg.zig each
/// parameter's type, and pg.zig converts to it, refusing what does not fit
/// (`error.IntWontFit`, mapped to `error.ValueOutOfRange`).
fn bindValue(stmt: *pg.Stmt, v: Value) !void {
    switch (v) {
        .null => try stmt.bind(null),
        .boolean => |b| try stmt.bind(b),
        .int => |i| try stmt.bind(i),
        // Postgres has no unsigned integers: a u64 past bigint's range
        // can't be stored or compared as one.
        .uint => |u| try stmt.bind(std.math.cast(i64, u) orelse return error.ValueOutOfRange),
        .float => |f| try stmt.bind(f),
        .string => |s| try stmt.bind(s),
    }
}

/// zom's shared error names for what Postgres and pg.zig report (see
/// `Gateway.Error`). Every Postgres error is also kept for `lastError()`
/// and logged at debug level (scope `.zom_pg`).
///
/// Every unique violation is `error.DuplicatePrimaryKey`, not only the
/// primary key's: telling them apart needs the constraint's name, which
/// can be anything, or a catalog query, which an aborted transaction
/// refuses. `lastError().constraint` names the one that was violated.
pub fn mapError(conn: *pg.Conn, err: anyerror) Gateway.Error {
    switch (err) {
        error.PG => if (conn.err) |pge| {
            record(pge);
            log.debug("postgres error {s}: {s}", .{ pge.code, pge.message });
            if (sqlstates.get(pge.code)) |mapped| return mapped;
            // Class 08: connection exceptions.
            if (std.mem.startsWith(u8, pge.code, "08")) return error.ConnectionFailed;
            return error.Database;
        },
        error.IntWontFit => return error.ValueOutOfRange,
        error.OutOfMemory => return error.OutOfMemory,
        error.Canceled => return error.Canceled,
        // pg.zig refuses statements on a connection in the failed state,
        // which inside a transaction means an earlier error aborted it.
        error.ConnectionBusy => if (conn._state == .fail) {
            log.debug("the transaction was aborted by an earlier error", .{});
            return error.Database;
        },
        else => {
            const name = @errorName(err);
            for (connection_errors) |c| if (std.mem.eql(u8, name, c)) {
                log.debug("connection error: {s}", .{name});
                return error.ConnectionFailed;
            };
        },
    }
    log.debug("pg.zig error: {t}", .{err});
    return error.Database;
}

/// The SQLSTATEs with a name of their own. The rest of class 08 is
/// `error.ConnectionFailed`, everything else `error.Database`.
const sqlstates = std.StaticStringMap(Gateway.Error).initComptime(.{
    .{ "23505", error.DuplicatePrimaryKey }, // unique_violation
    .{ "22003", error.ValueOutOfRange }, // numeric_value_out_of_range
    .{ "42P01", error.NotFound }, // undefined_table
    .{ "25006", error.ReadOnly }, // read_only_sql_transaction
});

/// A Postgres error, as `Gateway.lastError()` returns it.
pub const ServerError = struct {
    /// The SQLSTATE, e.g. "23505".
    code: []const u8,
    /// "ERROR", "FATAL", ...
    severity: []const u8,
    message: []const u8,
    detail: ?[]const u8 = null,
    hint: ?[]const u8 = null,
    table: ?[]const u8 = null,
    column: ?[]const u8 = null,
    constraint: ?[]const u8 = null,
};

/// Per thread, so concurrent calls through one pool each see their own.
/// Postgres messages are short; past `buf.len`, fields are cut short.
threadlocal var last_error: struct {
    buf: [2048]u8 = undefined,
    err: ?ServerError = null,
} = .{};

/// Copies `pge`, which lives in the connection until its next error, into
/// `last_error`.
fn record(pge: anytype) void {
    const store = &last_error;
    var used: usize = 0;
    const copy = struct {
        fn f(buf: []u8, at: *usize, v: []const u8) []const u8 {
            const n = @min(v.len, buf.len - at.*);
            const out = buf[at.*..][0..n];
            @memcpy(out, v[0..n]);
            at.* += n;
            return out;
        }
        fn opt(buf: []u8, at: *usize, v: ?[]const u8) ?[]const u8 {
            return if (v) |x| f(buf, at, x) else null;
        }
    };
    const b = &store.buf;
    store.err = .{
        .code = copy.f(b, &used, pge.code),
        .severity = copy.f(b, &used, pge.severity),
        .message = copy.f(b, &used, pge.message),
        .constraint = copy.opt(b, &used, pge.constraint),
        .table = copy.opt(b, &used, pge.table),
        .column = copy.opt(b, &used, pge.column),
        .detail = copy.opt(b, &used, pge.detail),
        .hint = copy.opt(b, &used, pge.hint),
    };
}

/// Socket-level failures, by name: pg.zig's error sets are inferred, so
/// they are matched on `@errorName` rather than listed in a `switch`.
const connection_errors = [_][]const u8{
    "ConnectionRefused",  "ConnectionResetByPeer", "BrokenPipe",          "EndOfStream",
    "NetworkUnreachable", "ConnectionTimedOut",    "HostUnreachable",     "NotOpenForReading",
    "SocketNotConnected", "Closed",                "UnknownHostName",     "TemporaryNameServerFailure",
    "NameServerFailure",  "ConnectionAborted",     "AddressNotAvailable", "Timeout",
};

// -- decoding ----------------------------------------------------------------

/// For each field of `P`, the index of its column in `result`, found by
/// name: `RETURNING *` lists the table's columns in table order, which
/// need not be the struct's.
fn columnMap(comptime P: type, result: *pg.Result) ![@typeInfo(P).@"struct".fields.len]usize {
    var columns: [@typeInfo(P).@"struct".fields.len]usize = undefined;
    inline for (@typeInfo(P).@"struct".fields, &columns) |f, *c| {
        c.* = result.columnIndex(f.name) orelse {
            log.debug("the result has no column '{s}'", .{f.name});
            return error.MissingColumn;
        };
    }
    return columns;
}

/// Decodes one row into `P`, copying strings into `allocator`. On error
/// the strings copied so far are freed.
fn decodeRow(comptime P: type, row: *const pg.Row, columns: []const usize, allocator: Allocator) !P {
    const fields = @typeInfo(P).@"struct".fields;
    var out: P = undefined;
    var done: usize = 0;
    errdefer inline for (fields, 0..) |f, i| {
        if (comptime zom.strings.isStringField(f.type)) {
            if (i < done) switch (@typeInfo(f.type)) {
                .optional => if (@field(out, f.name)) |s| allocator.free(s),
                else => allocator.free(@field(out, f.name)),
            };
        }
    };
    inline for (fields, 0..) |f, i| {
        @field(out, f.name) = decodeField(f.type, row, columns[i], allocator) catch |err| {
            log.debug("column '{s}' (oid {d}) could not be read as {s}: {t}", .{ f.name, row.oids[columns[i]], @typeName(f.type), err });
            return err;
        };
        done = i + 1;
    }
    return out;
}

const oid = struct {
    const bool_ = 16;
    const int8 = 20;
    const int2 = 21;
    const int4 = 23;
    const float4 = 700;
    const float8 = 701;
    const numeric = 1700;
};

/// pg.zig's `row.get` is strict about column types, so the column's oid
/// picks which Zig type to read it as, before converting to `F`.
fn decodeField(comptime F: type, row: *const pg.Row, col: usize, allocator: Allocator) !F {
    if (@typeInfo(F) == .optional) {
        if (row.values[col].is_null) return null;
        return try decodeField(@typeInfo(F).optional.child, row, col, allocator);
    }
    if (row.values[col].is_null) return error.UnexpectedNull;
    const col_oid = row.oids[col];
    switch (@typeInfo(F)) {
        .int => {
            const v: i64 = switch (col_oid) {
                oid.int2 => try row.get(i16, col),
                oid.int4 => try row.get(i32, col),
                oid.int8 => try row.get(i64, col),
                else => return error.ColumnTypeMismatch,
            };
            return std.math.cast(F, v) orelse error.ValueOutOfRange;
        },
        .float => return switch (col_oid) {
            oid.float4 => @floatCast(try row.get(f32, col)),
            oid.float8, oid.numeric => @floatCast(try row.get(f64, col)),
            else => error.ColumnTypeMismatch,
        },
        .bool => return if (col_oid == oid.bool_) try row.get(bool, col) else error.ColumnTypeMismatch,
        // Text, or a Postgres ENUM, whose value is its label.
        .@"enum" => return zom.codec.decodeField(F, try row.get([]const u8, col), .{}),
        .pointer => {
            if (comptime !zom.strings.isFreeableString(F)) @compileError("zom-pg: string attributes must be slices such as []const u8, found " ++ @typeName(F));
            const raw = try row.get([]const u8, col);
            if (comptime @typeInfo(F).pointer.sentinel() != null) return allocator.dupeZ(u8, raw);
            return allocator.dupe(u8, raw);
        },
        else => @compileError("zom-pg: unsupported attribute type " ++ @typeName(F)),
    }
}
