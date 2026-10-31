//! The CSV gateway = rom-csv's `ROM::CSV::Gateway`: a file or a directory of
//! CSV files, one dataset per `*.csv`, named after the file. Each dataset is a
//! `zom.memory.Store(S)` filled from its file on first use.
//!
//! The gateway itself is `zom.file.Gateway` over `Format` below, shared with
//! zom-yaml: it finds and reads the file, loads each dataset once, and syncs
//! atomically. See `zom.file` for those steps. This file is the CSV part:
//!
//! - `Gateway` is read-only. The dataset declares only `read` and `count`, so
//!   `relation.create`, `update` and `delete` on it are compile errors naming
//!   the `csv` adapter.
//! - `WritableGateway` adds `insert`, `insertMany`, `update` and `delete`,
//!   which change the in-memory store and mark the dataset dirty, and
//!   `sync()`, which writes dirty datasets back to their files.
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
//! `sync` writes the header and every row through `zom.codec` and
//! `csv.writeRow`. Columns keep the order of the header read at load time;
//! fields that header lacked follow, in schema order. A new file uses schema
//! order. `deinit` does not sync, as with rom-csv, where nothing reaches the
//! file without `sync!`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zom = @import("zom");
const csv = @import("csv.zig");
const fieldCount = zom.file.fieldCount;

pub const UnknownColumns = zom.file.Unknown;
pub const Diagnostic = zom.file.Diagnostic;

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
pub const Gateway = zom.file.Gateway(Format, .read_only);

/// Datasets also have `insert`, `insertMany`, `update`, `delete` and `sync`,
/// and the gateway has `sync`, which writes every dirty dataset.
pub const WritableGateway = zom.file.Gateway(Format, .writable);

/// What `writeTable` and the encoding half of `sync` can fail with.
/// `error.OutOfMemory` comes from the row buffer.
pub const WriteError = zom.codec.EncodeError || Allocator.Error;

/// What `sync` can fail with.
pub const SyncError = zom.file.SyncError(Format);

/// CSV for `zom.file.Gateway`.
pub const Format = struct {
    pub const name = "csv";
    pub const extension = ".csv";
    pub const layout: zom.file.Layout = .one_per_file;
    pub const Config = @import("gateway.zig").Config;
    pub const WriteError = @import("gateway.zig").WriteError;

    /// Field indices in the order `sync` writes the columns.
    pub fn State(comptime S: type) type {
        return [fieldCount(S.Tuple)]usize;
    }

    /// Loads the file into `store` and returns the field indices in the
    /// order of its header columns, then the fields it lacks. A missing file
    /// is an empty one with the fields in schema order.
    pub fn load(comptime S: type, ctx: zom.file.LoadContext(Format), store: *zom.memory.Store(S)) !State(S) {
        const T = S.Tuple;
        const field_count = comptime fieldCount(T);
        const cfg = ctx.config;
        const file = ctx.file;
        const text = ctx.bytes orelse return columnOrder(field_count, @splat(null));

        var reader = csv.Reader.init(ctx.allocator, text, .{ .separator = cfg.separator });
        defer reader.deinit();
        var csv_diag: csv.Diagnostic = .{};
        reader.diagnostic = &csv_diag;

        const header = (reader.next() catch |e| return csvError(ctx, csv_diag, e)) orelse {
            ctx.diagnostic.set("{s}: empty file, expected a header row with the fields of '{s}'", .{ file, S.name });
            return error.SchemaMismatch;
        };
        var columns: [field_count]?usize = @splat(null);
        try mapHeader(S, ctx, header, &columns);
        const width = header.len;

        while (reader.next() catch |e| return csvError(ctx, csv_diag, e)) |row| {
            if (row.len == 0) continue;
            if (row.len != width) {
                ctx.diagnostic.set("{s}:{d}: {d} cells, but the header has {d}", .{ file, reader.row_line, row.len, width });
                return error.WrongCellCount;
            }
            var d: zom.codec.Diagnostic = .{};
            const tuple = zom.codec.decodeRow(T, row, .{
                .null_text = cfg.null_text,
                .columns = &columns,
                .row = reader.row_line,
            }, &d) catch |e| {
                ctx.diagnostic.set("{s}:{f}", .{ file, d });
                return e;
            };
            _ = try store.load(tuple);
        }
        return columnOrder(field_count, columns);
    }

    pub fn dump(comptime S: type, ctx: zom.file.DumpContext(Format, S), w: *Io.Writer) Format.WriteError!void {
        const cfg = ctx.config;
        try writeRows(w, S.Tuple, ctx.rows, ctx.state, ctx.allocator, .{
            .separator = cfg.separator,
            .null_text = cfg.null_text,
            .line_ending = cfg.line_ending,
        });
    }

    /// Fills `columns[field] = cell index` from the header, and reports every
    /// problem with it in one message.
    fn mapHeader(comptime S: type, ctx: zom.file.LoadContext(Format), header: csv.Row, columns: []?usize) !void {
        const fields = @typeInfo(S.Tuple).@"struct".fields;
        const index = comptime zom.file.fieldIndex(S.Tuple);
        const ignore = ctx.config.unknown_columns == .ignore;

        var problems = ctx.diagnostic.list("{s}: header does not match '{s}':", .{ ctx.file, S.name });
        for (header, 0..) |col, cell| {
            const field = index.get(col) orelse {
                if (ignore and !ctx.writable) continue;
                problems.add("unknown column \"{s}\"{s}", .{ col, if (ignore) " (sync would drop it)" else "" });
                continue;
            };
            if (columns[field] != null) {
                problems.add("column \"{s}\" appears twice", .{col});
                continue;
            }
            columns[field] = cell;
        }
        inline for (fields, 0..) |f, i| {
            if (comptime zom.file.isRequired(f)) {
                if (columns[i] == null) problems.add("missing column \"{s}\"", .{f.name});
            }
        }
        if (problems.finish()) return error.SchemaMismatch;
    }

    fn csvError(ctx: zom.file.LoadContext(Format), d: csv.Diagnostic, err: csv.Error) csv.Error {
        if (err == error.OutOfMemory) return err;
        ctx.diagnostic.set("{s}:{f}", .{ ctx.file, d });
        return err;
    }
};

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
