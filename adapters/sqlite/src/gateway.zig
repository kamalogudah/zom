//! The SQLite gateway: one `sqlite3` connection, and one dataset per schema
//! whose statements come from zom-sql.
//!
//! Every read compiles the relation's query with `zom_sql` for the
//! `.sqlite` dialect, binds its `zom.Value` params with `sqlite3_bind_*`,
//! and decodes each row into the tuple by column name.
//!
//! String ownership (`strings = .caller`): SQLite's column text is only
//! valid until the next step of the statement, so every string a dataset
//! returns, from `read`, `readProjected` or `insert`, is copied into the
//! allocator passed to that call, and belongs to the caller. Free reads with
//! the relation's `free(allocator, rows)` and single tuples with
//! `freeOne(allocator, tuple)`, or read into an arena.
//!
//! Threads: a gateway is one connection, for one thread at a time. Open one
//! gateway per thread on the same file to share a database (with
//! `.journal_mode = .wal`, readers don't wait for a writer).
//!
//! Transactions: `transaction(ctx, f)` hands `f` the same gateway. Every
//! call on it inside `f`, through any relation, is part of the transaction,
//! and a nested `transaction` is a SAVEPOINT. Unlike Postgres, a failed
//! statement does not abort the transaction around it, so `f` may catch an
//! error and go on.
//!
//! Prepared statements: the connection keeps the statements it has run,
//! keyed by their SQL text, so a statement that comes back (a `get` by key,
//! every level of a `combine`, `insertMany` batches) is compiled once and
//! then only reset, bound and stepped. SQLite re-prepares a kept statement
//! by itself after the schema changes. See `Conn`.

const std = @import("std");
const zom = @import("zom");
const zom_sql = @import("zom_sql");
const c = @import("sqlite3");

const Allocator = std.mem.Allocator;
pub const Value = zom.Value;
const log = std.log.scoped(.zom_sqlite);
const dialect = zom_sql.Dialect.sqlite;

pub const Gateway = struct {
    pub const adapter_name = "sqlite";

    pub const Mode = enum {
        /// Opens the file, creating it if missing.
        read_write_create,
        /// Opens an existing file: `error.ConnectionFailed` if it is missing.
        read_write,
        /// Writes fail with `error.ReadOnly`.
        read_only,
    };

    pub const JournalMode = enum { delete, truncate, persist, memory, wal, off };

    /// How the outermost `transaction` begins. Nested ones are savepoints.
    pub const Begin = enum {
        /// `BEGIN`: the write lock is taken by the first write, which can
        /// then fail with `error.Busy` if another connection holds it.
        deferred,
        /// `BEGIN IMMEDIATE`: the write lock is taken at once, so a
        /// transaction that writes waits (`busy_timeout_ms`) up front.
        immediate,
    };

    pub const Config = struct {
        /// A file path, `":memory:"` for a private in-memory database, or a
        /// `file:` URI.
        path: []const u8 = ":memory:",
        mode: Mode = .read_write_create,
        /// How long a statement waits for another connection's lock before
        /// `error.Busy`. 0 fails at once.
        busy_timeout_ms: u32 = 5000,
        /// `PRAGMA foreign_keys`. SQLite's own default is off; zom's is on.
        foreign_keys: bool = true,
        /// `PRAGMA journal_mode`, or null to keep the database's.
        journal_mode: ?JournalMode = null,
        begin: Begin = .deferred,
        /// Most prepared statements the connection keeps (see `Conn`).
        /// When full, keeping another finalizes one of them. 0 prepares
        /// every statement on every call.
        statement_cache_size: u16 = 128,
    };

    allocator: Allocator,
    /// On the heap, so the gateway can move after `dataset` is called.
    conn: *Conn,
    /// One per schema, made by the first `dataset(S)` call.
    datasets: std.ArrayList(Entry) = .empty,

    /// What every zom-sqlite call can fail with, besides its own checks
    /// (`error.MissingColumn` and the like). The first five are zom's
    /// shared names (`zom.Error`).
    pub const Error = error{
        /// A `PRIMARY KEY` or `UNIQUE` constraint failed:
        /// `lastError().message` says which columns.
        DuplicatePrimaryKey,
        /// A parameter SQLite can't hold (an unsigned integer past 2^63-1).
        ValueOutOfRange,
        /// The schema's table does not exist.
        NotFound,
        /// The database was opened read-only, or its file can't be written.
        ReadOnly,
        /// The database file could not be opened.
        ConnectionFailed,
        /// Another connection held a lock past `busy_timeout_ms`.
        Busy,
        /// Any other SQLite error. `lastError()` has SQLite's message.
        Database,
        OutOfMemory,
    };

    /// The SQLite error a call on this thread last got, or null if there
    /// has been none. The message lives in a per-thread buffer (a long one
    /// is cut short), valid until the next SQLite error on this thread. A
    /// call that succeeds leaves it as it was, like `errno`.
    pub fn lastError() ?SqliteError {
        return last_error.err;
    }

    const Entry = struct {
        type_name: []const u8,
        ptr: *anyopaque,
        destroy: *const fn (*anyopaque, Allocator) void,
    };

    /// Opens the database and applies the config's pragmas.
    /// `error.ConnectionFailed` when the file can't be opened.
    pub fn init(allocator: Allocator, config: Config) !Gateway {
        const conn = try allocator.create(Conn);
        errdefer allocator.destroy(conn);
        conn.* = try Conn.open(allocator, config);
        return .{ .allocator = allocator, .conn = conn };
    }

    /// Finalizes every kept statement and closes the connection.
    pub fn deinit(self: *Gateway) void {
        for (self.datasets.items) |e| e.destroy(e.ptr, self.allocator);
        self.datasets.deinit(self.allocator);
        self.conn.close();
        self.allocator.destroy(self.conn);
        self.* = undefined;
    }

    pub fn Dataset(comptime S: type) type {
        return SqliteDataset(S);
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
        d.* = .{ .conn = self.conn };
        self.datasets.appendAssumeCapacity(.{ .type_name = name, .ptr = d, .destroy = D.destroy });
        return d;
    }

    /// Runs `sql`, which may hold several statements separated by `;`,
    /// with no parameters and no rows, e.g. `CREATE TABLE`. zom has no
    /// migrations; this is for setup and tests.
    pub fn exec(self: *Gateway, sql: []const u8) Error!void {
        return self.conn.exec(sql);
    }

    /// The raw `sqlite3` handle, for what zom-sqlite doesn't wrap (backups,
    /// custom functions, `sqlite3_changes64` after `exec`). Don't close it.
    pub fn handle(self: *Gateway) *c.sqlite3 {
        return self.conn.db;
    }

    /// `f(ctx, tx)` in a transaction: BEGIN (or a SAVEPOINT, when one is
    /// already open), then COMMIT when `f` returns, or ROLLBACK when it (or
    /// the COMMIT) fails, returning `f`'s error unchanged. Zig has no
    /// closures, so `f`'s state comes in through `ctx`. Returns what `f`
    /// returns.
    ///
    /// `tx` is this gateway: SQLite has one connection, and everything run
    /// on it inside `f` is in the transaction, through `tx` or not.
    pub fn transaction(self: *Gateway, ctx: anytype, comptime f: anytype) Transaction(@TypeOf(ctx), f) {
        const conn = self.conn;
        try conn.begin();
        // An error rolling back can't replace the one that caused it.
        errdefer conn.rollback();
        const out = if (comptime isErrorUnion(FnResult(@TypeOf(ctx), f))) try f(ctx, self) else f(ctx, self);
        try conn.commit();
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

    /// `@TypeOf(f(ctx, tx))`, which also works when `f` is generic.
    fn FnResult(comptime Ctx: type, comptime f: anytype) type {
        return @TypeOf(f(@as(Ctx, undefined), @as(*Gateway, undefined)));
    }
};

fn isErrorUnion(comptime T: type) bool {
    return @typeInfo(T) == .error_union;
}

/// The connection, its kept statements, and how deep the transactions
/// started through zom-sqlite are.
///
/// A kept statement is taken out of `cache` while it runs and put back
/// (reset, its bindings cleared) when it is done, so a statement running
/// the same SQL while another is still open, which zom never does but a
/// caller's own code might, gets a fresh one rather than sharing it.
pub const Conn = struct {
    db: *c.sqlite3,
    allocator: Allocator,
    /// Owned SQL text -> its prepared statement.
    cache: std.StringHashMapUnmanaged(*c.sqlite3_stmt) = .empty,
    cache_size: u16,
    begin_mode: Gateway.Begin,
    /// 0 outside `transaction`; n inside the n-th nested one.
    depth: u32 = 0,
    /// Whether the outermost `begin` found a transaction the caller opened
    /// (`exec("BEGIN")`), and so made a savepoint instead of a BEGIN.
    outer_is_callers: bool = false,
    /// Statements prepared, for tests of the cache.
    prepared: usize = 0,

    fn open(allocator: Allocator, config: Gateway.Config) Gateway.Error!Conn {
        const path = try allocator.dupeSentinel(u8, config.path, 0);
        defer allocator.free(path);
        const flags: c_int = c.SQLITE_OPEN_URI | c.SQLITE_OPEN_NOMUTEX | c.SQLITE_OPEN_EXRESCODE | switch (config.mode) {
            .read_write_create => c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE,
            .read_write => c.SQLITE_OPEN_READWRITE,
            .read_only => c.SQLITE_OPEN_READONLY,
        };
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open_v2(path.ptr, &db, flags, null);
        if (rc != c.SQLITE_OK) {
            // SQLite returns a handle even on most failures, for the message.
            if (db) |d| {
                record(d, rc);
                _ = c.sqlite3_close_v2(d);
            }
            log.debug("opening {s} failed: {d}", .{ config.path, rc });
            return if (rc == c.SQLITE_NOMEM) error.OutOfMemory else error.ConnectionFailed;
        }
        var conn: Conn = .{
            .db = db.?,
            .allocator = allocator,
            .cache_size = config.statement_cache_size,
            .begin_mode = config.begin,
        };
        errdefer _ = c.sqlite3_close_v2(conn.db);
        _ = c.sqlite3_busy_timeout(conn.db, std.math.cast(c_int, config.busy_timeout_ms) orelse std.math.maxInt(c_int));
        _ = c.sqlite3_extended_result_codes(conn.db, 1);

        try conn.exec(if (config.foreign_keys) "PRAGMA foreign_keys = ON" else "PRAGMA foreign_keys = OFF");
        if (config.journal_mode) |jm| {
            var buf: [64]u8 = undefined;
            try conn.exec(std.fmt.bufPrint(&buf, "PRAGMA journal_mode = {t}", .{jm}) catch unreachable);
        }
        return conn;
    }

    fn close(self: *Conn) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            _ = c.sqlite3_finalize(e.value_ptr.*);
            self.allocator.free(e.key_ptr.*);
        }
        self.cache.deinit(self.allocator);
        // v2: a statement a caller left open through `handle` doesn't keep
        // the file open forever; it closes once that is finalized.
        _ = c.sqlite3_close_v2(self.db);
    }

    fn exec(self: *Conn, sql: []const u8) Gateway.Error!void {
        const z = try self.allocator.dupeSentinel(u8, sql, 0);
        defer self.allocator.free(z);
        const rc = c.sqlite3_exec(self.db, z.ptr, null, null, null);
        if (rc != c.SQLITE_OK) return self.fail(rc);
    }

    /// `rc` as a `Gateway.Error`, recorded for `lastError()`.
    fn fail(self: *Conn, rc: c_int) Gateway.Error {
        return mapError(self.db, rc);
    }

    // -- statements ------------------------------------------------------

    /// A statement bound to `params`, kept or newly prepared. Run it with
    /// `step` and give it back with `finish`.
    fn prepare(self: *Conn, sql: []const u8, params: []const Value) (Gateway.Error || error{WrongNumberOfParameters})!Stmt {
        const stmt: Stmt = if (self.cache.fetchRemove(sql)) |kv|
            .{ .raw = kv.value, .key = kv.key }
        else
            .{ .raw = try self.prepareNew(sql), .key = null };
        errdefer self.finish(stmt);

        const n: usize = @intCast(c.sqlite3_bind_parameter_count(stmt.raw));
        if (n != params.len) return error.WrongNumberOfParameters;
        for (params, 1..) |p, i| {
            const rc = try bindValue(stmt.raw, @intCast(i), p);
            if (rc != c.SQLITE_OK) return self.fail(rc);
        }
        return stmt;
    }

    fn prepareNew(self: *Conn, sql: []const u8) Gateway.Error!*c.sqlite3_stmt {
        var raw: ?*c.sqlite3_stmt = null;
        const len = std.math.cast(c_int, sql.len) orelse return error.ValueOutOfRange;
        const flags: c_uint = if (self.cache_size > 0) c.SQLITE_PREPARE_PERSISTENT else 0;
        const rc = c.sqlite3_prepare_v3(self.db, sql.ptr, len, flags, &raw, null);
        if (rc != c.SQLITE_OK) {
            _ = c.sqlite3_finalize(raw);
            return self.fail(rc);
        }
        self.prepared += 1;
        // Empty SQL (only a comment) prepares to no statement.
        return raw orelse error.Database;
    }

    /// Resets the statement and keeps it, or finalizes it when the cache
    /// is off, full of others, or already has one for its SQL.
    fn finish(self: *Conn, stmt: Stmt) void {
        _ = c.sqlite3_reset(stmt.raw);
        _ = c.sqlite3_clear_bindings(stmt.raw);
        if (self.keep(stmt)) return;
        _ = c.sqlite3_finalize(stmt.raw);
        if (stmt.key) |k| self.allocator.free(k);
    }

    fn keep(self: *Conn, stmt: Stmt) bool {
        if (self.cache_size == 0) return false;
        const sql = stmt.sql();
        if (self.cache.contains(sql)) return false;
        if (self.cache.count() >= self.cache_size) self.evictOne();
        self.cache.ensureUnusedCapacity(self.allocator, 1) catch return false;
        const key = stmt.key orelse (self.allocator.dupe(u8, sql) catch return false);
        self.cache.putAssumeCapacityNoClobber(key, stmt.raw);
        return true;
    }

    fn evictOne(self: *Conn) void {
        var it = self.cache.iterator();
        const victim = it.next() orelse return;
        const key = victim.key_ptr.*;
        _ = c.sqlite3_finalize(victim.value_ptr.*);
        self.cache.removeByPtr(victim.key_ptr);
        self.allocator.free(key);
    }

    /// True when the statement produced a row, false when it is done.
    fn step(self: *Conn, stmt: Stmt) Gateway.Error!bool {
        return switch (c.sqlite3_step(stmt.raw)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => |rc| self.fail(rc),
        };
    }

    /// Runs a statement that returns no rows and returns how many it changed.
    fn run(self: *Conn, sql: []const u8, params: []const Value) !usize {
        const stmt = try self.prepare(sql, params);
        defer self.finish(stmt);
        while (try self.step(stmt)) {}
        return @intCast(c.sqlite3_changes64(self.db));
    }

    // -- transactions ----------------------------------------------------

    /// BEGIN, or a SAVEPOINT inside a transaction already open (by zom or
    /// by the caller's own `exec("BEGIN")`).
    fn begin(self: *Conn) Gateway.Error!void {
        const depth = self.depth;
        var buf: [64]u8 = undefined;
        if (depth == 0) self.outer_is_callers = c.sqlite3_get_autocommit(self.db) == 0;
        if (self.isOutermost(depth)) {
            try self.exec(switch (self.begin_mode) {
                .deferred => "BEGIN",
                .immediate => "BEGIN IMMEDIATE",
            });
        } else {
            try self.exec(savepoint(&buf, "SAVEPOINT zom_{d}", depth));
        }
        self.depth = depth + 1;
    }

    /// COMMIT, or RELEASE the savepoint. A COMMIT that fails (`error.Busy`)
    /// leaves the transaction open for the caller's `rollback`.
    fn commit(self: *Conn) Gateway.Error!void {
        const depth = self.depth - 1;
        var buf: [64]u8 = undefined;
        if (self.isOutermost(depth)) {
            try self.exec("COMMIT");
        } else {
            try self.exec(savepoint(&buf, "RELEASE SAVEPOINT zom_{d}", depth));
        }
        self.depth = depth;
    }

    /// ROLLBACK, or roll back to the savepoint and drop it, which leaves
    /// the outer transaction as it was before. Errors are dropped: the
    /// caller is already returning one. Skipped when SQLite has already
    /// rolled the transaction back itself (after `SQLITE_FULL` and the like).
    fn rollback(self: *Conn) void {
        const depth = self.depth - 1;
        self.depth = depth;
        if (c.sqlite3_get_autocommit(self.db) != 0) return;
        var buf: [96]u8 = undefined;
        const sql = if (self.isOutermost(depth))
            "ROLLBACK"
        else
            savepoint(&buf, "ROLLBACK TO SAVEPOINT zom_{[0]d}; RELEASE SAVEPOINT zom_{[0]d}", depth);
        self.exec(sql) catch |err| log.debug("{s} failed: {t}", .{ sql, err });
    }

    /// Whether the transaction at `depth` is the one `begin` opened with
    /// BEGIN rather than a savepoint. Every depth but 0 is a savepoint, and
    /// so is 0 inside the caller's own BEGIN, which `begin` saw.
    fn isOutermost(self: *Conn, depth: u32) bool {
        return depth == 0 and !self.outer_is_callers;
    }
};

/// A prepared statement, and the SQL it was kept under, if it was.
const Stmt = struct {
    raw: *c.sqlite3_stmt,
    /// The cache's copy of the SQL when the statement came from it.
    key: ?[]const u8,

    fn sql(self: Stmt) []const u8 {
        if (self.key) |k| return k;
        return std.mem.span(c.sqlite3_sql(self.raw));
    }
};

fn savepoint(buf: []u8, comptime fmt: []const u8, depth: u32) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{depth}) catch unreachable;
}

fn SqliteDataset(comptime S: type) type {
    return struct {
        const Self = @This();
        const T = S.Tuple;
        const Q = zom.Query(T);
        const table = S.name;

        /// Everything zom-sql renders, joins included.
        pub const supports: zom.Supports = .all;
        /// See the top of this file.
        pub const strings: zom.StringOwnership = .caller;

        conn: *Conn,

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

            const conn = self.conn;
            const stmt = try conn.prepare(compiled.sql, compiled.params);
            defer conn.finish(stmt);

            var rows: std.ArrayList(P) = .empty;
            errdefer {
                for (rows.items) |r| zom.strings.freeFields(P, allocator, r, &.{});
                rows.deinit(allocator);
            }
            const columns = try columnMap(P, stmt.raw);
            while (try conn.step(stmt)) {
                try rows.ensureUnusedCapacity(allocator, 1);
                rows.appendAssumeCapacity(try decodeRow(P, stmt.raw, &columns, allocator));
            }
            return rows.toOwnedSlice(allocator);
        }

        pub fn count(self: *Self, query: Q) !usize {
            const a = self.conn.allocator;
            const compiled = zom_sql.compileSelect(dialect, T, a, table, query) catch |err| switch (err) {
                error.InvalidNullComparison => return if (query.isConjunction()) 0 else err,
                else => |e| return e,
            };
            defer compiled.deinit(a);
            // Counting the SELECT keeps its limit and offset.
            const sql = try a.print("SELECT COUNT(*) FROM ({s}) AS \"zom_count\"", .{compiled.sql});
            defer a.free(sql);

            const conn = self.conn;
            const stmt = try conn.prepare(sql, compiled.params);
            defer conn.finish(stmt);
            if (!try conn.step(stmt)) return error.UnexpectedResult;
            const n = c.sqlite3_column_int64(stmt.raw, 0);
            return std.math.cast(usize, n) orelse error.UnexpectedResult;
        }

        /// `INSERT ... RETURNING *`: the stored tuple, as SQLite has it (a
        /// column default or a trigger shows). Its strings belong to
        /// `allocator`. `error.DuplicatePrimaryKey` on a unique violation.
        pub fn insert(self: *Self, row: T, allocator: Allocator) !T {
            const conn = self.conn;
            const a = conn.allocator;
            const compiled = try zom_sql.compileInsert(dialect, T, a, table, row);
            defer compiled.deinit(a);

            const stmt = try conn.prepare(compiled.sql, compiled.params);
            defer conn.finish(stmt);
            if (!try conn.step(stmt)) return error.UnexpectedResult;
            const columns = try columnMap(T, stmt.raw);
            const stored = try decodeRow(T, stmt.raw, &columns, allocator);
            errdefer zom.strings.freeFields(T, allocator, stored, &.{});
            // RETURNING rows come before the write is final: step to the
            // end, where a constraint checked late (a deferred foreign
            // key) still fails the insert.
            while (try conn.step(stmt)) {}
            return stored;
        }

        /// All or nothing: the multi-row `INSERT`s zom-sql splits the batch
        /// into run in a SAVEPOINT (or a transaction of their own), so a
        /// failed batch leaves an enclosing transaction usable.
        pub fn insertMany(self: *Self, rows: []const T) !usize {
            if (rows.len == 0) return 0;
            const conn = self.conn;
            const a = conn.allocator;
            const batch = try zom_sql.compileInsertMany(dialect, T, a, table, rows);
            defer batch.deinit(a);

            try conn.begin();
            errdefer conn.rollback();
            var n: usize = 0;
            for (batch.statements) |s| n += try conn.run(s.sql, s.params);
            try conn.commit();
            return n;
        }

        /// The number of rows changed. A change whose value does not fit
        /// the attribute's Zig type is `error.ValueOutOfRange`; SQLite's
        /// columns would take it.
        pub fn update(self: *Self, query: Q, changes: []const Q.Change) !usize {
            for (changes) |ch| try checkFits(ch);
            var everything = query;
            // A relation with no filters means every row, as in memory.
            everything.all = true;
            const a = self.conn.allocator;
            const compiled = zom_sql.compileUpdate(dialect, T, a, table, everything, changes) catch |err| switch (err) {
                error.EmptyUpdate => return 0,
                error.InvalidNullComparison => return if (query.isConjunction()) 0 else err,
                else => |e| return e,
            };
            defer compiled.deinit(a);
            return self.conn.run(compiled.sql, compiled.params);
        }

        /// The number of rows deleted. No filters deletes every row.
        pub fn delete(self: *Self, query: Q) !usize {
            var everything = query;
            everything.all = true;
            const a = self.conn.allocator;
            const compiled = zom_sql.compileDelete(dialect, T, a, table, everything) catch |err| switch (err) {
                error.InvalidNullComparison => return if (query.isConjunction()) 0 else err,
                else => |e| return e,
            };
            defer compiled.deinit(a);
            return self.conn.run(compiled.sql, compiled.params);
        }

        fn checkFits(ch: Q.Change) !void {
            switch (ch.field) {
                inline else => |f| {
                    const F = @FieldType(T, @tagName(f));
                    _ = try zom.query.fromValue(F, ch.value);
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

// -- binding -----------------------------------------------------------------

/// One `zom.Value` as parameter `i` (1-based). SQLite has no unsigned
/// integers and nothing wider than 64 bits, so a `uint` or `uint128` past
/// 2^63-1 is refused rather than bound as text or a float, which an
/// integer column would keep as such. Strings are bound without a copy
/// (`SQLITE_STATIC`): they outlive the statement's run, and `finish`
/// clears the bindings.
fn bindValue(stmt: *c.sqlite3_stmt, i: c_int, v: Value) error{ValueOutOfRange}!c_int {
    return switch (v) {
        .null => c.sqlite3_bind_null(stmt, i),
        .boolean => |b| c.sqlite3_bind_int64(stmt, i, @intFromBool(b)),
        .int, .uint, .uint128 => c.sqlite3_bind_int64(stmt, i, try int64(v)),
        .float => |f| c.sqlite3_bind_double(stmt, i, f),
        .string => |s| c.sqlite3_bind_text64(stmt, i, s.ptr, s.len, null, c.SQLITE_UTF8),
    };
}

fn int64(v: Value) error{ValueOutOfRange}!i64 {
    return switch (v) {
        .int => |i| i,
        .uint => |u| std.math.cast(i64, u) orelse error.ValueOutOfRange,
        .uint128 => |u| std.math.cast(i64, u) orelse error.ValueOutOfRange,
        else => unreachable,
    };
}

test "int64: uint and uint128 bind when they fit, ValueOutOfRange past 2^63-1" {
    const max = std.math.maxInt(i64);
    try std.testing.expectEqual(-1, try int64(.{ .int = -1 }));
    try std.testing.expectEqual(max, try int64(.{ .uint = max }));
    try std.testing.expectEqual(max, try int64(.{ .uint128 = max }));
    try std.testing.expectError(error.ValueOutOfRange, int64(.{ .uint = max + 1 }));
    try std.testing.expectError(error.ValueOutOfRange, int64(.{ .uint128 = std.math.maxInt(u128) }));
}

// -- errors ------------------------------------------------------------------

/// zom's shared error names for SQLite's result codes (see
/// `Gateway.Error`). Every error is also kept for `lastError()` and logged
/// at debug level (scope `.zom_sqlite`).
fn mapError(db: *c.sqlite3, rc: c_int) Gateway.Error {
    record(db, rc);
    const msg = std.mem.span(c.sqlite3_errmsg(db));
    log.debug("sqlite error {d}: {s}", .{ rc, msg });
    return switch (rc) {
        c.SQLITE_CONSTRAINT_PRIMARYKEY, c.SQLITE_CONSTRAINT_UNIQUE => error.DuplicatePrimaryKey,
        c.SQLITE_NOMEM => error.OutOfMemory,
        c.SQLITE_TOOBIG => error.ValueOutOfRange,
        else => switch (rc & 0xff) {
            c.SQLITE_READONLY => error.ReadOnly,
            c.SQLITE_BUSY, c.SQLITE_LOCKED => error.Busy,
            c.SQLITE_CANTOPEN, c.SQLITE_NOTADB => error.ConnectionFailed,
            // A missing table is a prepare error with no code of its own.
            c.SQLITE_ERROR => if (std.mem.startsWith(u8, msg, "no such table")) error.NotFound else error.Database,
            else => error.Database,
        },
    };
}

/// A SQLite error, as `Gateway.lastError()` returns it.
pub const SqliteError = struct {
    /// The extended result code, e.g. 1555 (`SQLITE_CONSTRAINT_PRIMARYKEY`).
    code: c_int,
    /// `sqlite3_errmsg`, e.g. "UNIQUE constraint failed: users.email".
    message: []const u8,

    /// The primary result code: `code & 0xff`, e.g. 19 (`SQLITE_CONSTRAINT`).
    pub fn primary(self: SqliteError) c_int {
        return self.code & 0xff;
    }
};

threadlocal var last_error: struct {
    buf: [1024]u8 = undefined,
    err: ?SqliteError = null,
} = .{};

fn record(db: *c.sqlite3, rc: c_int) void {
    const msg = std.mem.span(c.sqlite3_errmsg(db));
    const n = @min(msg.len, last_error.buf.len);
    @memcpy(last_error.buf[0..n], msg[0..n]);
    last_error.err = .{ .code = rc, .message = last_error.buf[0..n] };
}

// -- decoding ----------------------------------------------------------------

/// For each field of `P`, the index of its column in the statement's
/// result, found by name: `RETURNING *` lists the table's columns in table
/// order, which need not be the struct's.
fn columnMap(comptime P: type, stmt: *c.sqlite3_stmt) ![@typeInfo(P).@"struct".field_names.len]c_int {
    var columns: [@typeInfo(P).@"struct".field_names.len]c_int = undefined;
    const n = c.sqlite3_column_count(stmt);
    inline for (@typeInfo(P).@"struct".field_names, &columns) |field_name, *col| {
        col.* = for (0..@intCast(n)) |i| {
            const name = c.sqlite3_column_name(stmt, @intCast(i)) orelse return error.OutOfMemory;
            if (std.mem.eql(u8, std.mem.span(name), field_name)) break @intCast(i);
        } else {
            log.debug("the result has no column '{s}'", .{field_name});
            return error.MissingColumn;
        };
    }
    return columns;
}

/// Decodes the current row into `P`, copying strings into `allocator`. On
/// error the strings copied so far are freed.
fn decodeRow(comptime P: type, stmt: *c.sqlite3_stmt, columns: []const c_int, allocator: Allocator) !P {
    const info = @typeInfo(P).@"struct";
    var out: P = undefined;
    var done: usize = 0;
    errdefer inline for (info.field_names, info.field_types, 0..) |field_name, F, i| {
        if (comptime zom.strings.isStringField(F)) {
            if (i < done) switch (@typeInfo(F)) {
                .optional => if (@field(out, field_name)) |s| allocator.free(s),
                else => allocator.free(@field(out, field_name)),
            };
        }
    };
    inline for (info.field_names, info.field_types, 0..) |field_name, F, i| {
        @field(out, field_name) = decodeField(F, stmt, columns[i], allocator) catch |err| {
            log.debug("column '{s}' (type {d}) could not be read as {s}: {t}", .{ field_name, c.sqlite3_column_type(stmt, columns[i]), @typeName(F), err });
            return err;
        };
        done = i + 1;
    }
    return out;
}

/// SQLite types values, not columns, so the value's own type (its storage
/// class) picks how to read it. A value of the wrong class is
/// `error.ColumnTypeMismatch`: text in an integer field is not parsed.
fn decodeField(comptime F: type, stmt: *c.sqlite3_stmt, col: c_int, allocator: Allocator) !F {
    const class = c.sqlite3_column_type(stmt, col);
    if (@typeInfo(F) == .optional) {
        if (class == c.SQLITE_NULL) return null;
        return try decodeField(@typeInfo(F).optional.child, stmt, col, allocator);
    }
    if (class == c.SQLITE_NULL) return error.UnexpectedNull;
    switch (@typeInfo(F)) {
        .int => {
            if (class != c.SQLITE_INTEGER) return error.ColumnTypeMismatch;
            return std.math.cast(F, c.sqlite3_column_int64(stmt, col)) orelse error.ValueOutOfRange;
        },
        .float => return switch (class) {
            c.SQLITE_FLOAT, c.SQLITE_INTEGER => @floatCast(c.sqlite3_column_double(stmt, col)),
            else => error.ColumnTypeMismatch,
        },
        // SQLite has no booleans: `TRUE` and `FALSE` are 1 and 0.
        .bool => return switch (class) {
            c.SQLITE_INTEGER => switch (c.sqlite3_column_int64(stmt, col)) {
                0 => false,
                1 => true,
                else => error.ColumnTypeMismatch,
            },
            else => error.ColumnTypeMismatch,
        },
        .@"enum" => {
            if (class != c.SQLITE_TEXT) return error.ColumnTypeMismatch;
            return zom.codec.decodeField(F, columnBytes(stmt, col, class), .{});
        },
        .pointer => {
            if (comptime !zom.strings.isFreeableString(F)) @compileError("zom-sqlite: string attributes must be slices such as []const u8, found " ++ @typeName(F));
            if (class != c.SQLITE_TEXT and class != c.SQLITE_BLOB) return error.ColumnTypeMismatch;
            const raw = columnBytes(stmt, col, class);
            if (comptime @typeInfo(F).pointer.sentinel() != null) return allocator.dupeSentinel(u8, raw, 0);
            return allocator.dupe(u8, raw);
        },
        else => @compileError("zom-sqlite: unsupported attribute type " ++ @typeName(F)),
    }
}

/// The value's bytes, valid until the next step. Text or blob only.
fn columnBytes(stmt: *c.sqlite3_stmt, col: c_int, class: c_int) []const u8 {
    // The pointer first, then the length: asking for text may convert.
    const ptr: ?[*]const u8 = if (class == c.SQLITE_TEXT)
        c.sqlite3_column_text(stmt, col)
    else
        @ptrCast(c.sqlite3_column_blob(stmt, col));
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    return if (ptr) |p| p[0..len] else "";
}
