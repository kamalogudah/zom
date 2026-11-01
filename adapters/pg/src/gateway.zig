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

const std = @import("std");
const zom = @import("zom");
const zom_sql = @import("zom_sql");
const pg = @import("pg");

const Allocator = std.mem.Allocator;
const Value = zom.Value;
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
    pool: *pg.Pool,
    /// One per schema, made by the first `dataset(S)` call.
    datasets: std.ArrayList(Entry) = .empty,

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
        return .{ .allocator = allocator, .pool = pool };
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

    pub fn deinit(self: *Gateway) void {
        for (self.datasets.items) |e| e.destroy(e.ptr, self.allocator);
        self.datasets.deinit(self.allocator);
        self.pool.deinit();
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
        d.* = .{ .pool = self.pool, .allocator = self.allocator };
        self.datasets.appendAssumeCapacity(.{ .type_name = name, .ptr = d, .destroy = D.destroy });
        return d;
    }

    /// Runs `sql` with no parameters and no rows, e.g. `CREATE TABLE`. zom
    /// has no migrations; this is for setup and tests.
    pub fn exec(self: *Gateway, sql: []const u8) !void {
        const conn = try acquire(self.pool);
        defer self.pool.release(conn);
        _ = conn.exec(sql, .{}) catch |err| return mapError(conn, err);
    }
};

fn acquire(pool: *pg.Pool) !*pg.Conn {
    return pool.acquire() catch |err| {
        log.debug("acquiring a connection failed: {t}", .{err});
        return if (err == error.OutOfMemory) error.OutOfMemory else error.ConnectionFailed;
    };
}

fn PgDataset(comptime S: type) type {
    return struct {
        const Self = @This();
        const T = S.Tuple;
        const Q = zom.Query(T);
        const table = S.name;

        /// Everything zom-sql renders, except joins.
        pub const supports: zom.Supports = .{
            .@"or" = true,
            .in = true,
            .like = true,
            .order_on = true,
            .offset = true,
            .projection = true,
        };
        /// See the top of this file.
        pub const strings: zom.StringOwnership = .caller;

        /// The gateway's, which lives on the heap, so the gateway itself
        /// may move after `dataset` is called.
        pool: *pg.Pool,
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

            const conn = try acquire(self.pool);
            defer self.pool.release(conn);
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

            const conn = try acquire(self.pool);
            defer self.pool.release(conn);
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

            const conn = try acquire(self.pool);
            defer self.pool.release(conn);
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
        /// into run in one transaction.
        pub fn insertMany(self: *Self, rows: []const T) !usize {
            if (rows.len == 0) return 0;
            const a = self.allocator;
            const batch = try zom_sql.compileInsertMany(dialect, T, a, table, rows);
            defer batch.deinit(a);

            const conn = try acquire(self.pool);
            defer self.pool.release(conn);
            conn.begin() catch |err| return mapError(conn, err);
            errdefer conn.rollback() catch {};
            var n: usize = 0;
            for (batch.statements) |s| n += try runCounting(conn, s.sql, s.params);
            conn.commit() catch |err| return mapError(conn, err);
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
            const conn = try acquire(self.pool);
            defer self.pool.release(conn);
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
fn run(conn: *pg.Conn, sql: []const u8, params: []const Value) !*pg.Result {
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

fn next(conn: *pg.Conn, result: *pg.Result) !?pg.Row {
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

/// zom's shared error names for what Postgres and pg.zig report. Other
/// Postgres errors are `error.PG`, with the message logged at debug level
/// (scope `.zom_pg`).
fn mapError(conn: *pg.Conn, err: anyerror) anyerror {
    switch (err) {
        error.PG => if (conn.err) |pge| {
            log.debug("postgres error {s}: {s}", .{ pge.code, pge.message });
            if (pge.isUnique()) return error.DuplicatePrimaryKey;
            // numeric_value_out_of_range.
            if (std.mem.eql(u8, pge.code, "22003")) return error.ValueOutOfRange;
            // read_only_sql_transaction: a replica or a read-only session.
            if (std.mem.eql(u8, pge.code, "25006")) return error.ReadOnly;
            // Class 08: connection exceptions.
            if (std.mem.startsWith(u8, pge.code, "08")) return error.ConnectionFailed;
        },
        error.IntWontFit => return error.ValueOutOfRange,
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const name = @errorName(err);
            for (connection_errors) |c| if (std.mem.eql(u8, name, c)) {
                log.debug("connection error: {s}", .{name});
                return error.ConnectionFailed;
            };
        },
    }
    return err;
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
