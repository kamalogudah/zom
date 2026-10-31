//! The CSV gateway = rom-csv's `ROM::CSV::Gateway`: a file or a directory of
//! CSV files, one dataset per `*.csv`, named after the file. Each dataset is a
//! `zom.memory.Store(S)` filled from its file on first use.
//!
//! Read-only. The dataset declares only `read` and `count`, so
//! `relation.create`, `update` and `delete` on it are compile errors naming the
//! `csv` adapter. Writes come as a second type, `WritableGateway`, not as a
//! `Config.writable` flag: capabilities are what a dataset type declares, and
//! a runtime flag cannot add or remove declarations. A separate type also
//! keeps `zom_csv.Gateway` a plain type, which is what `zom.Container` takes.
//!
//! Loading, on the first `dataset(S)` for a schema:
//!
//! 1. The file is `<path>/<S.name>.csv` when `path` is a directory, or `path`
//!    itself when it is a file whose stem is `S.name` (`data/users.csv` holds
//!    only `users`). Anything else is `error.NotFound`.
//! 2. It is read whole, up to `Config.max_file_bytes`, and parsed with
//!    `csv.Reader`. A leading UTF-8 byte order mark is skipped.
//! 3. The first row is the header. Columns may come in any order. Every
//!    field that is neither optional nor defaulted needs a column; a missing
//!    one, an unknown one (unless `unknown_columns = .ignore`) or a repeated
//!    one is `error.SchemaMismatch`.
//! 4. Every other row is decoded with `zom.codec` and loaded into the store,
//!    which copies its strings, and the file buffer is freed. Blank lines are
//!    skipped; a row with a different number of cells than the header is
//!    `error.WrongCellCount`. Primary keys are not checked for duplicates
//!    (`Store.load`), as the file is the source of truth.
//!
//! Every load error leaves a message in `gateway.diagnostic`, prefixed with
//! the file and, for a row, `row:column` (CSV line, 1-based cell):
//! `data/users.csv:3:4 (age): "abc" is not an integer from 0 to 255`.

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

/// What went wrong on the last failed load, as one line of text. Zig errors
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

pub const Gateway = struct {
    pub const adapter_name = "csv";

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
        /// The cell text that means `null` for an optional field.
        null_text: []const u8 = "",
        unknown_columns: UnknownColumns = .reject,
        /// A larger file is `error.FileTooBig`.
        max_file_bytes: usize = 64 * 1024 * 1024,
    };

    allocator: Allocator,
    config: Config,
    datasets: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Set when `dataset` fails to load a file.
    diagnostic: Diagnostic = .{},

    /// A type-erased `*Dataset(S)`, as in `zom.memory.Gateway`.
    const Entry = struct {
        ptr: *anyopaque,
        deinit_fn: *const fn (*anyopaque, Allocator) void,
        type_name: []const u8,
    };

    /// Records the config. Nothing is read until the first `dataset` call.
    pub fn init(allocator: Allocator, config: Config) Gateway {
        return .{ .allocator = allocator, .config = config };
    }

    pub fn deinit(self: *Gateway) void {
        var it = self.datasets.valueIterator();
        while (it.next()) |entry| entry.deinit_fn(entry.ptr, self.allocator);
        self.datasets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn Dataset(comptime S: type) type {
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

    /// The dataset for `S`, loading its file the first time. A failed load
    /// is not remembered: the next call tries again.
    pub fn dataset(self: *Gateway, comptime S: type) !*Dataset(S) {
        const D = Dataset(S);
        if (self.datasets.get(S.name)) |entry| {
            if (!std.mem.eql(u8, entry.type_name, @typeName(S))) return error.DatasetTypeMismatch;
            return @ptrCast(@alignCast(entry.ptr));
        }

        const d = try self.allocator.create(D);
        errdefer self.allocator.destroy(d);
        d.* = .{ .store = .init(self.allocator) };
        errdefer d.store.deinit();
        try self.load(S, &d.store);

        try self.datasets.put(self.allocator, S.name, .{
            .ptr = d,
            .deinit_fn = destroyFn(D),
            .type_name = @typeName(S),
        });
        return d;
    }

    fn destroyFn(comptime D: type) *const fn (*anyopaque, Allocator) void {
        return struct {
            fn destroy(ptr: *anyopaque, allocator: Allocator) void {
                const d: *D = @ptrCast(@alignCast(ptr));
                d.store.deinit();
                allocator.destroy(d);
            }
        }.destroy;
    }

    fn load(self: *Gateway, comptime S: type, store: *zom.memory.Store(S)) !void {
        const T = S.Tuple;
        const field_count = @typeInfo(T).@"struct".fields.len;
        const cfg = self.config;

        const file = try self.filePath(S.name);
        defer self.allocator.free(file);

        const bytes = cfg.dir.readFileAlloc(cfg.io, file, self.allocator, .limited(cfg.max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => {
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
    }

    /// `<path>/<name>.csv` for a directory, `path` for a file named `name`.
    /// The caller frees the result.
    fn filePath(self: *Gateway, name: []const u8) ![]u8 {
        const cfg = self.config;
        const st = cfg.dir.statFile(cfg.io, cfg.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                self.diagnostic.set("{s}: no such file or directory", .{cfg.path});
                return error.NotFound;
            },
            else => |e| return e,
        };
        if (st.kind == .directory) {
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
    fn mapHeader(self: *Gateway, comptime S: type, file: []const u8, header: csv.Row, columns: []?usize) !void {
        const fields = @typeInfo(S.Tuple).@"struct".fields;
        const index = comptime fieldIndex(S.Tuple);

        var w: Io.Writer = .fixed(&self.diagnostic.buf);
        var problems: usize = 0;
        w.print("{s}: header does not match '{s}':", .{ file, S.name }) catch {};

        for (header, 0..) |name, cell| {
            const field = index.get(name) orelse {
                if (self.config.unknown_columns == .ignore) continue;
                problems += 1;
                w.print(" unknown column \"{s}\";", .{name}) catch {};
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

    fn csvError(self: *Gateway, file: []const u8, d: csv.Diagnostic, err: csv.Error) csv.Error {
        if (err == error.OutOfMemory) return err;
        self.diagnostic.set("{s}:{f}", .{ file, d });
        return err;
    }
};

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
) !void {
    const fields = @typeInfo(T).@"struct".fields;
    const csv_options: csv.Options = .{ .separator = options.separator, .line_ending = options.line_ending };

    var names: [fields.len][]const u8 = undefined;
    inline for (fields, 0..) |f, i| names[i] = f.name;
    try csv.writeRow(writer, &names, csv_options);

    var text: Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    var ends: [fields.len]usize = undefined;
    var cells: [fields.len][]const u8 = undefined;
    for (rows) |row| {
        text.clearRetainingCapacity();
        inline for (fields, 0..) |f, i| {
            try zom.codec.encodeField(&text.writer, @field(row, f.name), .{ .null_text = options.null_text });
            ends[i] = text.written().len;
        }
        const all = text.written();
        var start: usize = 0;
        for (&cells, ends) |*cell, end| {
            cell.* = all[start..end];
            start = end;
        }
        try csv.writeRow(writer, &cells, csv_options);
    }
}
