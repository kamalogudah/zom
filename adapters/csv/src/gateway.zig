//! The CSV gateway = rom-csv's `ROM::CSV::Gateway`: a file or a directory of
//! CSV files, one dataset per `*.csv`, named after the file. Each dataset is a
//! `zom.memory.Store(S)` filled from its file on first use.
//!
//! Two types share one implementation:
//!
//! - `Gateway` is read-only. The dataset declares only `read` and `count`, so
//!   `relation.create`, `update` and `delete` on it are compile errors naming
//!   the `csv` adapter.
//! - `WritableGateway` adds `insert`, `insertMany`, `update` and `delete`,
//!   which change the in-memory store and mark the dataset dirty, and
//!   `sync()`, which writes dirty datasets back to their files.
//!
//! Writability is a second type, not a `Config.writable` flag: capabilities
//! are what a dataset type declares, and a runtime flag cannot add or remove
//! declarations. A separate type also keeps both plain types, which is what
//! `zom.Container` takes.
//!
//! Loading, on the first `dataset(S)` for a schema:
//!
//! 1. The file is `<path>/<S.name>.csv` when `path` is a directory, or `path`
//!    itself when it is a file whose stem is `S.name` (`data/users.csv` holds
//!    only `users`). Anything else is `error.NotFound`. A writable gateway
//!    also takes a `path` ending in `.csv` that does not exist yet.
//! 2. It is read whole, up to `Config.max_file_bytes`, and parsed with
//!    `csv.Reader`. A leading UTF-8 byte order mark is skipped. A missing
//!    file is `error.NotFound` on `Gateway`, and an empty dataset on
//!    `WritableGateway` (the file is created by the first `sync` after a
//!    write).
//! 3. The first row is the header. Columns may come in any order. Every
//!    field that is neither optional nor defaulted needs a column; a missing
//!    one, an unknown one (unless `unknown_columns = .ignore`) or a repeated
//!    one is `error.SchemaMismatch`. `WritableGateway` rejects unknown
//!    columns even with `.ignore`, because `sync` would drop them.
//! 4. Every other row is decoded with `zom.codec` and loaded into the store,
//!    which copies its strings, and the file buffer is freed. Blank lines are
//!    skipped; a row with a different number of cells than the header is
//!    `error.WrongCellCount`. Primary keys are not checked for duplicates
//!    (`Store.load`), as the file is the source of truth.
//!
//! Every load error leaves a message in `gateway.diagnostic`, prefixed with
//! the file and, for a row, `row:column` (CSV line, 1-based cell):
//! `data/users.csv:3:4 (age): "abc" is not an integer from 0 to 255`.
//!
//! Syncing (`WritableGateway` only), per dirty dataset:
//!
//! 1. The header and every row are written, through `zom.codec` and
//!    `csv.writeRow`, to `<file>.tmp` in the same directory, which is then
//!    flushed, fsynced and closed. Columns keep the order of the header read
//!    at load time; fields that header lacked follow, in schema order. A new
//!    file uses schema order.
//! 2. The temp file is renamed over `<file>`. A rename within one file
//!    system is atomic, so a reader sees the old file or the new one, never
//!    a mix. The new file gets the old one's permissions.
//! 3. On any error the temp file is deleted, the original is untouched, and
//!    the dataset stays dirty, so `sync` can be retried.
//!
//! `deinit` does not sync: unsynced writes are dropped, as with rom-csv,
//! where nothing reaches the file without `sync!`. Writing a file is a step
//! that can fail, and `deinit` cannot return an error. One process should
//! write a directory at a time: two syncing the same dataset share the
//! temp file name.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zom = @import("zom");
const csv = @import("csv.zig");

pub const UnknownColumns = enum {
    /// A header column that matches no field is `error.SchemaMismatch`.
    reject,
    /// Columns that match no field are skipped.
    ignore,
};

/// What went wrong on the last failed load or sync, as one line of text. Zig errors
/// carry no data, so the gateway writes the details here.
pub const Diagnostic = struct {
    pub const max_len = 1024;

    buf: [max_len]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    /// Replaces the message. One that doesn't fit is cut and ends in `...`.
    fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        var w: Io.Writer = .fixed(&d.buf);
        w.print(fmt, args) catch {
            @memcpy(d.buf[max_len - 3 ..], "...");
            d.len = max_len;
            return;
        };
        d.len = w.end;
    }
};

pub const Config = struct {
    /// Does the file I/O. Tests pass `std.testing.io`.
    io: Io,
    /// A directory holding `<dataset name>.csv` files, or one CSV file
    /// whose stem is the dataset name. Relative to `dir`. Borrowed.
    path: []const u8,
    /// What a relative `path` is resolved against. Borrowed: it must stay
    /// open as long as the gateway.
    dir: Io.Dir = .cwd(),
    separator: u8 = ',',
    /// The cell text that means `null` for an optional field. Borrowed.
    null_text: []const u8 = "",
    unknown_columns: UnknownColumns = .reject,
    /// A larger file is `error.FileTooBig`.
    max_file_bytes: usize = 64 * 1024 * 1024,
    /// What `sync` ends each row with. Reading accepts `\n` and `\r\n`
    /// whatever this is. Borrowed.
    line_ending: []const u8 = "\n",
};

/// Read-only: datasets have `read` and `count`.
pub const Gateway = GatewayType(.read_only);

/// Datasets also have `insert`, `insertMany`, `update`, `delete` and `sync`,
/// and the gateway has `sync`, which writes every dirty dataset.
pub const WritableGateway = GatewayType(.writable);

const Mode = enum { read_only, writable };

/// What `writeTable` and the encoding half of `sync` can fail with.
/// `error.OutOfMemory` comes from the row buffer.
pub const WriteError = zom.codec.EncodeError || Allocator.Error;

/// What `sync` can fail with.
pub const SyncError = WriteError || Io.File.OpenError || Io.File.Writer.Error ||
    Io.File.SyncError || Io.Dir.RenameError;

fn GatewayType(comptime mode: Mode) type {
    const writable = mode == .writable;
    return struct {
        const Self = @This();

        pub const adapter_name = "csv";
        pub const Config = @import("gateway.zig").Config;

        allocator: Allocator,
        config: Self.Config,
        datasets: std.StringHashMapUnmanaged(Entry) = .empty,
        /// Set when `dataset` fails to load a file, or `sync` to write one.
        diagnostic: Diagnostic = .{},

        /// A type-erased `*Dataset(S)`, as in `zom.memory.Gateway`.
        const Entry = struct {
            ptr: *anyopaque,
            deinit_fn: *const fn (*anyopaque, Allocator) void,
            sync_fn: if (writable) *const fn (*anyopaque, *Diagnostic) SyncError!void else void,
            type_name: []const u8,
        };

        /// Records the config. Nothing is read until the first `dataset` call.
        pub fn init(allocator: Allocator, config: Self.Config) Self {
            return .{ .allocator = allocator, .config = config };
        }

        /// Frees every dataset. Does not sync: writes not yet synced are
        /// dropped. Call `sync` first to keep them.
        pub fn deinit(self: *Self) void {
            var it = self.datasets.valueIterator();
            while (it.next()) |entry| entry.deinit_fn(entry.ptr, self.allocator);
            self.datasets.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn Dataset(comptime S: type) type {
            return if (writable) WritableDataset(S) else ReadOnlyDataset(S);
        }

        /// The dataset for `S`, loading its file the first time. A failed load
        /// is not remembered: the next call tries again.
        pub fn dataset(self: *Self, comptime S: type) !*Dataset(S) {
            const D = Dataset(S);
            if (self.datasets.get(S.name)) |entry| {
                if (!std.mem.eql(u8, entry.type_name, @typeName(S))) return error.DatasetTypeMismatch;
                return @ptrCast(@alignCast(entry.ptr));
            }

            const file = try self.filePath(S.name);
            // A writable dataset keeps the path, to sync to.
            defer if (!writable) self.allocator.free(file);
            errdefer if (writable) self.allocator.free(file);

            const d = try self.allocator.create(D);
            errdefer self.allocator.destroy(d);
            d.* = .{ .store = .init(self.allocator) };
            errdefer d.store.deinit();
            const order = try self.load(S, file, &d.store);
            if (writable) {
                d.order = order;
                d.target = .{
                    .allocator = self.allocator,
                    .io = self.config.io,
                    .dir = self.config.dir,
                    .file = file,
                    .options = .{
                        .separator = self.config.separator,
                        .null_text = self.config.null_text,
                        .line_ending = self.config.line_ending,
                    },
                };
            }

            try self.datasets.put(self.allocator, S.name, .{
                .ptr = d,
                .deinit_fn = destroyFn(D),
                .sync_fn = if (writable) syncFn(D) else {},
                .type_name = @typeName(S),
            });
            return d;
        }

        /// Writes every dirty dataset back to its file, atomically (see the
        /// module comment). Stops at the first failure and leaves a message
        /// in `diagnostic`; that dataset and those not yet written stay
        /// dirty, and their files are unchanged.
        pub fn sync(self: *Self) SyncError!void {
            if (!writable) @compileError("zom-csv: Gateway is read-only and has no sync; use zom_csv.WritableGateway");
            var it = self.datasets.valueIterator();
            while (it.next()) |entry| try entry.sync_fn(entry.ptr, &self.diagnostic);
        }

        fn destroyFn(comptime D: type) *const fn (*anyopaque, Allocator) void {
            return struct {
                fn destroy(ptr: *anyopaque, allocator: Allocator) void {
                    const d: *D = @ptrCast(@alignCast(ptr));
                    d.store.deinit();
                    if (writable) allocator.free(d.target.file);
                    allocator.destroy(d);
                }
            }.destroy;
        }

        fn syncFn(comptime D: type) *const fn (*anyopaque, *Diagnostic) SyncError!void {
            return struct {
                fn sync(ptr: *anyopaque, diagnostic: *Diagnostic) SyncError!void {
                    const d: *D = @ptrCast(@alignCast(ptr));
                    d.sync() catch |err| {
                        diagnostic.set("{s}: sync failed: {t}", .{ d.target.file, err });
                        return err;
                    };
                }
            }.sync;
        }

        /// Loads `file` into `store` and returns the field indices in the
        /// order of its header columns, then the fields it lacks, for `sync`
        /// to write them back in. A writable gateway treats a missing file as
        /// an empty one with the fields in schema order.
        fn load(self: *Self, comptime S: type, file: []const u8, store: *zom.memory.Store(S)) ![fieldCount(S.Tuple)]usize {
            const T = S.Tuple;
            const field_count = comptime fieldCount(T);
            const cfg = self.config;

            const bytes = cfg.dir.readFileAlloc(cfg.io, file, self.allocator, .limited(cfg.max_file_bytes)) catch |err| switch (err) {
                error.FileNotFound => {
                    if (writable) return columnOrder(field_count, @splat(null));
                    self.diagnostic.set("{s}: no such file", .{file});
                    return error.NotFound;
                },
                error.StreamTooLong => {
                    self.diagnostic.set("{s}: larger than max_file_bytes ({d})", .{ file, cfg.max_file_bytes });
                    return error.FileTooBig;
                },
                else => |e| {
                    self.diagnostic.set("{s}: {t}", .{ file, e });
                    return e;
                },
            };
            defer self.allocator.free(bytes);

            const bom = "\xEF\xBB\xBF";
            const text = if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;

            var reader = csv.Reader.init(self.allocator, text, .{ .separator = cfg.separator });
            defer reader.deinit();
            var csv_diag: csv.Diagnostic = .{};
            reader.diagnostic = &csv_diag;

            const header = (reader.next() catch |e| return self.csvError(file, csv_diag, e)) orelse {
                self.diagnostic.set("{s}: empty file, expected a header row with the fields of '{s}'", .{ file, S.name });
                return error.SchemaMismatch;
            };
            var columns: [field_count]?usize = @splat(null);
            try self.mapHeader(S, file, header, &columns);
            const width = header.len;

            while (reader.next() catch |e| return self.csvError(file, csv_diag, e)) |row| {
                if (row.len == 0) continue;
                if (row.len != width) {
                    self.diagnostic.set("{s}:{d}: {d} cells, but the header has {d}", .{ file, reader.row_line, row.len, width });
                    return error.WrongCellCount;
                }
                var d: zom.codec.Diagnostic = .{};
                const tuple = zom.codec.decodeRow(T, row, .{
                    .null_text = cfg.null_text,
                    .columns = &columns,
                    .row = reader.row_line,
                }, &d) catch |e| {
                    self.diagnostic.set("{s}:{f}", .{ file, d });
                    return e;
                };
                _ = try store.load(tuple);
            }
            return columnOrder(field_count, columns);
        }

        /// `<path>/<name>.csv` for a directory, `path` for a file named `name`.
        /// The caller frees the result.
        fn filePath(self: *Self, name: []const u8) ![]u8 {
            const cfg = self.config;
            const kind: Io.File.Kind = if (cfg.dir.statFile(cfg.io, cfg.path, .{})) |st| st.kind else |err| switch (err) {
                // A writable gateway may create the file `sync` writes.
                error.FileNotFound => if (writable and std.mem.eql(u8, std.fs.path.extension(cfg.path), ".csv")) .file else {
                    self.diagnostic.set("{s}: no such file or directory", .{cfg.path});
                    return error.NotFound;
                },
                else => |e| return e,
            };
            if (kind == .directory) {
                const file_name = try std.fmt.allocPrint(self.allocator, "{s}.csv", .{name});
                if (std.mem.eql(u8, cfg.path, ".")) return file_name;
                defer self.allocator.free(file_name);
                return std.fs.path.join(self.allocator, &.{ cfg.path, file_name });
            }
            if (!std.mem.eql(u8, std.fs.path.stem(cfg.path), name)) {
                self.diagnostic.set("{s}: holds the dataset '{s}', not '{s}'", .{ cfg.path, std.fs.path.stem(cfg.path), name });
                return error.NotFound;
            }
            return self.allocator.dupe(u8, cfg.path);
        }

        /// Fills `columns[field] = cell index` from the header, and reports every
        /// problem with it in one message.
        fn mapHeader(self: *Self, comptime S: type, file: []const u8, header: csv.Row, columns: []?usize) !void {
            const fields = @typeInfo(S.Tuple).@"struct".fields;
            const index = comptime fieldIndex(S.Tuple);
            const ignore = self.config.unknown_columns == .ignore;

            var w: Io.Writer = .fixed(&self.diagnostic.buf);
            var problems: usize = 0;
            w.print("{s}: header does not match '{s}':", .{ file, S.name }) catch {};

            for (header, 0..) |name, cell| {
                const field = index.get(name) orelse {
                    if (ignore and !writable) continue;
                    problems += 1;
                    w.print(" unknown column \"{s}\"{s};", .{ name, if (ignore) " (sync would drop it)" else "" }) catch {};
                    continue;
                };
                if (columns[field] != null) {
                    problems += 1;
                    w.print(" column \"{s}\" appears twice;", .{name}) catch {};
                    continue;
                }
                columns[field] = cell;
            }
            inline for (fields, 0..) |f, i| {
                const required = @typeInfo(f.type) != .optional and f.defaultValue() == null;
                if (required and columns[i] == null) {
                    problems += 1;
                    w.print(" missing column \"{s}\";", .{f.name}) catch {};
                }
            }
            if (problems == 0) return;

            self.diagnostic.len = w.end;
            if (w.end == w.buffer.len) {
                @memcpy(self.diagnostic.buf[Diagnostic.max_len - 3 ..], "...");
            } else {
                self.diagnostic.len -= 1; // the last ';'
            }
            return error.SchemaMismatch;
        }

        fn csvError(self: *Self, file: []const u8, d: csv.Diagnostic, err: csv.Error) csv.Error {
            if (err == error.OutOfMemory) return err;
            self.diagnostic.set("{s}:{f}", .{ file, d });
            return err;
        }
    };
}

fn ReadOnlyDataset(comptime S: type) type {
    return struct {
        const Self = @This();
        const Q = zom.Query(S.Tuple);
        const Store = zom.memory.Store(S);

        pub const supports: zom.Supports = Store.supports;

        store: Store,

        pub fn read(self: *Self, query: Q, allocator: Allocator) ![]S.Tuple {
            return self.store.read(query, allocator);
        }

        pub fn count(self: *Self, query: Q) !usize {
            return self.store.count(query);
        }
    };
}

/// Where a writable dataset syncs to.
const Target = struct {
    allocator: Allocator,
    io: Io,
    dir: Io.Dir,
    /// Relative to `dir`. Owned by the dataset.
    file: []const u8,
    options: WriteOptions,
};

fn WritableDataset(comptime S: type) type {
    return struct {
        const Self = @This();
        const T = S.Tuple;
        const Q = zom.Query(T);
        const Store = zom.memory.Store(S);

        pub const supports: zom.Supports = Store.supports;

        store: Store,
        target: Target = undefined,
        /// Field indices in the order `sync` writes the columns.
        order: [fieldCount(T)]usize = undefined,
        /// Set by every write that changes a row, cleared by a successful
        /// `sync`.
        dirty: bool = false,

        pub fn read(self: *Self, query: Q, allocator: Allocator) ![]T {
            return self.store.read(query, allocator);
        }

        pub fn count(self: *Self, query: Q) !usize {
            return self.store.count(query);
        }

        pub fn insert(self: *Self, row: T) !T {
            const stored = try self.store.insert(row);
            self.dirty = true;
            return stored;
        }

        pub fn insertMany(self: *Self, batch: []const T) !usize {
            const n = try self.store.insertMany(batch);
            if (n > 0) self.dirty = true;
            return n;
        }

        pub fn update(self: *Self, query: Q, changes: []const Q.Change) !usize {
            const n = try self.store.update(query, changes);
            if (n > 0) self.dirty = true;
            return n;
        }

        pub fn delete(self: *Self, query: Q) !usize {
            const n = try self.store.delete(query);
            if (n > 0) self.dirty = true;
            return n;
        }

        /// Writes the header and every row to the file, if anything changed
        /// since the load or the last sync. Atomic: on error the file is
        /// unchanged and the dataset stays dirty. `WritableGateway.sync` does
        /// this for every dataset and also reports the file in `diagnostic`.
        pub fn sync(self: *Self) SyncError!void {
            if (!self.dirty) return;
            try writeFileAtomic(self.target, self, writeBody);
            self.dirty = false;
        }

        fn writeBody(self: *const Self, w: *Io.Writer) WriteError!void {
            try writeRows(w, T, self.store.rows(), &self.order, self.target.allocator, self.target.options);
        }
    };
}

/// Writes `t.file` atomically: `body(ctx, writer)` fills `<file>.tmp` in the
/// same directory, which is flushed, fsynced, closed and then renamed over
/// `t.file`. On error the temp file is deleted and `t.file` is untouched.
fn writeFileAtomic(t: Target, ctx: anytype, comptime body: anytype) SyncError!void {
    const tmp = try std.fmt.allocPrint(t.allocator, "{s}.tmp", .{t.file});
    defer t.allocator.free(tmp);

    // Keep the old file's mode, so a sync does not widen or narrow access.
    const permissions: Io.File.Permissions = if (t.dir.statFile(t.io, t.file, .{})) |st|
        modeBits(st.permissions)
    else |_|
        .default_file;

    const file = try t.dir.createFile(t.io, tmp, .{ .permissions = permissions });
    errdefer t.dir.deleteFile(t.io, tmp) catch {};
    {
        // Closed before the rename, which Windows requires.
        defer file.close(t.io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(t.io, &buf);
        body(ctx, &fw.interface) catch |err| switch (err) {
            error.WriteFailed => return fw.err orelse error.WriteFailed,
            else => |e| return e,
        };
        try fw.flush();
        try file.sync(t.io);
    }
    try t.dir.rename(tmp, t.dir, t.file, t.io);
}

/// `stat` reports the file type bits too; `createFile` wants only the mode.
fn modeBits(p: Io.File.Permissions) Io.File.Permissions {
    if (@hasDecl(Io.File.Permissions, "fromMode")) return .fromMode(p.toMode() & 0o7777);
    return p;
}

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".fields.len;
}

/// Field indices sorted by their header cell, then those with no cell, in
/// declaration order.
fn columnOrder(comptime n: usize, columns: [n]?usize) [n]usize {
    var order: [n]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    std.sort.insertion(usize, &order, columns, struct {
        fn lessThan(cols: [n]?usize, a: usize, b: usize) bool {
            const ca = cols[a] orelse return false;
            const cb = cols[b] orelse return true;
            return ca < cb;
        }
    }.lessThan);
    return order;
}

/// Field name -> index in declaration order.
fn fieldIndex(comptime T: type) std.StaticStringMap(usize) {
    const fields = @typeInfo(T).@"struct".fields;
    var kvs: [fields.len]struct { []const u8, usize } = undefined;
    for (fields, 0..) |f, i| kvs[i] = .{ f.name, i };
    return .initComptime(kvs);
}

pub const WriteOptions = struct {
    separator: u8 = ',',
    null_text: []const u8 = "",
    line_ending: []const u8 = "\n",
};

/// Writes a header of `T`'s field names and one row per tuple, in the format
/// the gateway reads back. `allocator` holds one encoded row at a time.
pub fn writeTable(
    writer: *Io.Writer,
    comptime T: type,
    rows: []const T,
    allocator: Allocator,
    options: WriteOptions,
) WriteError!void {
    const identity = comptime blk: {
        var o: [fieldCount(T)]usize = undefined;
        for (&o, 0..) |*x, i| x.* = i;
        break :blk o;
    };
    return writeRows(writer, T, rows, &identity, allocator, options);
}

/// `writeTable` with the columns in `order` (field indices).
fn writeRows(
    writer: *Io.Writer,
    comptime T: type,
    rows: []const T,
    order: *const [fieldCount(T)]usize,
    allocator: Allocator,
    options: WriteOptions,
) WriteError!void {
    const fields = @typeInfo(T).@"struct".fields;
    const csv_options: csv.Options = .{ .separator = options.separator, .line_ending = options.line_ending };
    const names = comptime blk: {
        var n: [fields.len][]const u8 = undefined;
        for (fields, 0..) |f, i| n[i] = f.name;
        break :blk n;
    };

    var cells: [fields.len][]const u8 = undefined;
    for (&cells, order) |*cell, field| cell.* = names[field];
    try csv.writeRow(writer, &cells, csv_options);

    var text: Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var ends: [fields.len]usize = undefined;
    for (rows) |row| {
        text.clearRetainingCapacity();
        inline for (fields, 0..) |f, i| {
            zom.codec.encodeField(&text.writer, @field(row, f.name), .{ .null_text = options.null_text }) catch |err| switch (err) {
                // `text` only fails when it cannot grow.
                error.WriteFailed => return error.OutOfMemory,
                else => |e| return e,
            };
            ends[i] = text.written().len;
        }
        const all = text.written();
        for (&cells, order) |*cell, field| {
            cell.* = all[if (field == 0) 0 else ends[field - 1]..ends[field]];
        }
        try csv.writeRow(writer, &cells, csv_options);
    }
}

test "writeFileAtomic: a body that fails midway leaves the original byte-for-byte unchanged" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "id,name\r\n1,\"Ada\"\r\n\xEF\xBB\xBF";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = original });

    const Failing = struct {
        /// Writes more than the file writer buffers, so part of it reaches
        /// the temp file, then fails as an encoder would.
        fn body(_: void, w: *Io.Writer) WriteError!void {
            for (0..4) |_| try w.splatByteAll('x', 8192);
            return error.NullNotRepresentable;
        }
    };
    const t: Target = .{ .allocator = testing.allocator, .io = testing.io, .dir = tmp.dir, .file = "users.csv", .options = .{} };
    try testing.expectError(error.NullNotRepresentable, writeFileAtomic(t, {}, Failing.body));

    const got = try tmp.dir.readFileAlloc(testing.io, "users.csv", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, original, got);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "users.csv.tmp", .{}));
}

test "sync survives running out of memory, leaving the file as it was" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.checkAllAllocationFailures(testing.allocator, insertAndSync, .{tmp.dir});
}

fn insertAndSync(allocator: Allocator, dir: Io.Dir) !void {
    const testing = std.testing;
    const S = zom.Schema(struct { id: u32, name: []const u8 }, "users", .id);
    const original = "name,id\nAda,1\n";
    try dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = original });

    var gw = WritableGateway.init(allocator, .{ .io = testing.io, .dir = dir, .path = "." });
    defer gw.deinit();
    const d = try gw.dataset(S);
    _ = try d.insert(.{ .id = 2, .name = "a \"quoted\" name" });
    gw.sync() catch |err| {
        const got = try dir.readFileAlloc(testing.io, "users.csv", testing.allocator, .unlimited);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(original, got);
        try testing.expect(d.dirty);
        return err;
    };
    const got = try dir.readFileAlloc(testing.io, "users.csv", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("name,id\nAda,1\n\"a \"\"quoted\"\" name\",2\n", got);
}
