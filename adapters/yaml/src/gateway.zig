//! The YAML gateway = rom-yaml's `ROM::YAML::Gateway`. `Config.path` is
//! either:
//!
//! - one YAML file mapping every dataset name to its records (rom-yaml's
//!   single file), parsed with `yaml.parseDatasets`:
//!
//!   ```yaml
//!   users:
//!     - id: 1
//!       name: Ada
//!   posts: []
//!   ```
//!
//! - or a directory with one `<dataset name>.yaml` per dataset, each a bare
//!   sequence of records, parsed with `yaml.parseRecords`.
//!
//! Each dataset is a `zom.memory.Store(S)` filled on its first `dataset(S)`.
//! The gateway is `zom.file.Gateway` over `Format` below, shared with zom-csv:
//! finding and reading the file, loading once, the read-only and writable
//! types, and atomic `sync` are described in `zom.file`. This file is the
//! YAML part.
//!
//! Loading a dataset:
//!
//! 1. The file is parsed (see `yaml.zig` for the subset). A parse error is
//!    reported with its line and column: `users.yaml:3:5: unsupported YAML:
//!    an anchor (&name)`.
//! 2. In a single file, a dataset that isn't there is `error.NotFound` on
//!    `Gateway`, and an empty dataset on `WritableGateway`.
//! 3. Each record's keys are checked against the schema's fields. A missing
//!    key for a field that is neither optional nor defaulted, and an unknown
//!    key (unless `unknown_keys = .ignore`), are `error.SchemaMismatch`.
//!    The message names the file, the record's line, the dataset, the
//!    record's 0-based index in the list, and every bad key:
//!    `users.yaml:7: users[1]: missing key "name"; unknown key "email"`.
//!    `WritableGateway` rejects unknown keys even with `.ignore`, because
//!    `sync` would drop them.
//! 4. Values are decoded with `zom.codec`. YAML null (`~`, `null`, nothing)
//!    is null for an optional field, even one with a default, and
//!    `error.UnexpectedNull` for any other field. A quoted value is text, so
//!    `""` is an empty string, not null. Decode errors give the key's line:
//!    `users.yaml:9: users[2].age: "old" is not an integer from 0 to 255`.
//! 5. Rows go into the store, which copies their strings. Primary keys are
//!    not checked for duplicates (`Store.load`): the file is the source of
//!    truth.
//!
//! Syncing (`WritableGateway`) writes every record with its keys in schema
//! order and null as `~`. Strings that another YAML reader would take as a
//! number, bool or null are quoted (`"123"`, `"yes"`), as is anything the
//! parser could not read back plain. In a single file, the other datasets
//! are written back as the file holds them at sync time, in the same order,
//! with their values quoted where they were quoted. A dataset new to the
//! file goes last. Comments and formatting are not kept.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zom = @import("zom");
const yaml = @import("yaml.zig");

pub const UnknownKeys = zom.file.Unknown;
pub const Diagnostic = zom.file.Diagnostic;

pub const Config = struct {
    /// Does the file I/O. Tests pass `std.testing.io`.
    io: Io,
    /// A YAML file holding every dataset, or a directory of
    /// `<dataset name>.yaml` files. Relative to `dir`. Borrowed.
    path: []const u8,
    /// What a relative `path` is resolved against. Borrowed: it must stay
    /// open as long as the gateway.
    dir: Io.Dir = .cwd(),
    unknown_keys: UnknownKeys = .reject,
    /// A larger file is `error.FileTooBig`.
    max_file_bytes: usize = 64 * 1024 * 1024,
};

/// Read-only: datasets have `read` and `count`.
pub const Gateway = zom.file.Gateway(Format, .read_only);

/// Datasets also have `insert`, `insertMany`, `update`, `delete` and `sync`,
/// and the gateway has `sync`, which writes every dirty dataset.
pub const WritableGateway = zom.file.Gateway(Format, .writable);

/// What `writeRecords`, `writeDataset` and the encoding half of `sync` can
/// fail with. `yaml.Error` comes from re-reading a single file at sync time;
/// `error.OutOfMemory` from the value buffer.
pub const WriteError = zom.codec.EncodeError || yaml.Error;

/// What `sync` can fail with.
pub const SyncError = zom.file.SyncError(Format);

/// YAML for `zom.file.Gateway`.
pub const Format = struct {
    pub const name = "yaml";
    pub const extension = ".yaml";
    pub const layout: zom.file.Layout = .all_in_file;
    pub const Config = @import("gateway.zig").Config;
    pub const WriteError = @import("gateway.zig").WriteError;

    const LoadContext = zom.file.LoadContext(Format);

    pub fn load(comptime S: type, ctx: LoadContext, store: *zom.memory.Store(S)) !void {
        const bytes = ctx.bytes orelse return;
        var diag: yaml.Diagnostic = .{};
        if (ctx.all_in_file) {
            var parsed = yaml.parseDatasets(ctx.allocator, bytes, &diag) catch |e| return parseError(ctx, diag, e);
            defer parsed.deinit();
            const d = parsed.get(S.name) orelse {
                if (ctx.writable) return;
                ctx.diagnostic.set("{s}: no dataset '{s}'", .{ ctx.file, S.name });
                return error.NotFound;
            };
            return loadRecords(S, ctx, d.records, store);
        }
        var parsed = yaml.parseRecords(ctx.allocator, bytes, &diag) catch |e| return parseError(ctx, diag, e);
        defer parsed.deinit();
        return loadRecords(S, ctx, parsed.items, store);
    }

    pub fn dump(comptime S: type, ctx: zom.file.DumpContext(Format, S), w: *Io.Writer) Format.WriteError!void {
        if (!ctx.all_in_file) return writeRecords(w, S.Tuple, ctx.rows, ctx.allocator);

        var diag: yaml.Diagnostic = .{};
        var current = yaml.parseDatasets(ctx.allocator, ctx.current orelse "", &diag) catch |e| {
            if (e != error.OutOfMemory) ctx.diagnostic.set("{s}:{f} (sync reads the file again to keep its other datasets)", .{ ctx.file, diag });
            return e;
        };
        defer current.deinit();
        var written = false;
        for (current.items) |d| {
            if (std.mem.eql(u8, d.name, S.name)) {
                try writeDataset(w, S.Tuple, S.name, ctx.rows, ctx.allocator);
                written = true;
            } else {
                try writeParsedDataset(w, d);
            }
        }
        if (!written) try writeDataset(w, S.Tuple, S.name, ctx.rows, ctx.allocator);
    }

    fn parseError(ctx: LoadContext, d: yaml.Diagnostic, err: yaml.Error) yaml.Error {
        if (err != error.OutOfMemory) ctx.diagnostic.set("{s}:{f}", .{ ctx.file, d });
        return err;
    }

    fn loadRecords(comptime S: type, ctx: LoadContext, records: []const yaml.Record, store: *zom.memory.Store(S)) !void {
        const T = S.Tuple;
        const info = @typeInfo(T).@"struct";
        const fields = info.field_names;
        const index = comptime zom.file.fieldIndex(T);
        const ignore = ctx.config.unknown_keys == .ignore;

        for (records, 0..) |rec, i| {
            // `cells[f]` is field f's text when `columns[f] == f`; `nulls[f]`
            // the line of an explicit null.
            var cells: [fields.len][]const u8 = undefined;
            var columns: [fields.len]?usize = @splat(null);
            var nulls: [fields.len]?usize = @splat(null);

            var problems = ctx.diagnostic.list("{s}:{d}: {s}[{d}]:", .{ ctx.file, rec.line, S.name, i });
            for (rec.fields) |f| {
                const fi = index.get(f.key) orelse {
                    if (ignore and !ctx.writable) continue;
                    problems.add("unknown key \"{s}\"{s}", .{ f.key, if (ignore) " (sync would drop it)" else "" });
                    continue;
                };
                // The parser rejects a key used twice in one record.
                if (f.value) |v| {
                    cells[fi] = v;
                    columns[fi] = fi;
                } else nulls[fi] = f.line;
            }
            inline for (info.field_names, info.field_types, info.field_attrs, 0..) |field_name, F, attrs, fi| {
                if (comptime zom.file.isRequired(F, attrs)) {
                    if (columns[fi] == null and nulls[fi] == null) problems.add("missing key \"{s}\"", .{field_name});
                }
            }
            if (problems.finish()) return error.SchemaMismatch;

            inline for (info.field_names, info.field_types, 0..) |field_name, F, fi| {
                if (@typeInfo(F) != .optional) if (nulls[fi]) |line| {
                    ctx.diagnostic.set("{s}:{d}: {s}[{d}].{s}: null, but the field is not optional", .{ ctx.file, line, S.name, i, field_name });
                    return error.UnexpectedNull;
                };
            }

            var d: zom.codec.Diagnostic = .{};
            // `null_text = null`: YAML null is structural, not a text, and
            // was handled above.
            var tuple = zom.codec.decodeRow(T, &cells, .{ .null_text = null, .columns = &columns, .row = rec.line }, &d) catch |e| {
                const line = if (rec.get(d.field)) |f| f.line else rec.line;
                ctx.diagnostic.set("{s}:{d}: {s}[{d}].{s}: {f}", .{ ctx.file, line, S.name, i, d.field, std.fmt.alt(d, .formatProblem) });
                return e;
            };
            // `decodeRow` gave a missing value the field's default; an
            // explicit null wins over it.
            inline for (info.field_names, info.field_types, 0..) |field_name, F, fi| {
                if (@typeInfo(F) == .optional) {
                    if (nulls[fi] != null) @field(tuple, field_name) = null;
                }
            }
            _ = try store.load(tuple);
        }
    }
};

/// Writes `rows` as a bare sequence of records, the format of a
/// `<name>.yaml` file in a directory. No rows is an empty file.
/// `allocator` holds one encoded value at a time.
pub fn writeRecords(w: *Io.Writer, comptime T: type, rows: []const T, allocator: Allocator) WriteError!void {
    var buf: Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    for (rows) |row| try writeRecord(w, T, row, "", &buf);
}

/// Writes `name:` and `rows` indented under it, or `name: []` for no rows:
/// one entry of a single YAML file holding every dataset. Concatenating
/// entries with different names gives such a file.
pub fn writeDataset(w: *Io.Writer, comptime T: type, name: []const u8, rows: []const T, allocator: Allocator) WriteError!void {
    try yaml.writeScalar(w, name, .string);
    if (rows.len == 0) return w.writeAll(": []\n");
    try w.writeAll(":\n");
    var buf: Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    for (rows) |row| try writeRecord(w, T, row, "  ", &buf);
}

fn writeRecord(w: *Io.Writer, comptime T: type, row: T, indent: []const u8, buf: *Io.Writer.Allocating) WriteError!void {
    inline for (@typeInfo(T).@"struct".field_names, 0..) |name, i| {
        try w.writeAll(indent);
        try w.writeAll(if (i == 0) "- " else "  ");
        try yaml.writeScalar(w, name, .plain_if_safe);
        try w.writeAll(": ");
        try writeValue(w, @field(row, name), buf);
        try w.writeByte('\n');
    }
}

fn writeValue(w: *Io.Writer, value: anytype, buf: *Io.Writer.Allocating) WriteError!void {
    const F = @TypeOf(value);
    if (@typeInfo(F) == .optional) {
        if (value) |v| return writeValue(w, v, buf);
        return yaml.writeScalar(w, null, .plain_if_safe);
    }
    if (F == []const u8) return yaml.writeScalar(w, value, .string);
    buf.clearRetainingCapacity();
    zom.codec.encodeField(&buf.writer, value, .{ .null_text = null }) catch |err| switch (err) {
        // `buf` only fails when it cannot grow.
        error.WriteFailed => return error.OutOfMemory,
        else => |e| return e,
    };
    // An enum tag may be `null` or `yes`; numbers and bools stay plain.
    try yaml.writeScalar(w, buf.written(), if (@typeInfo(F) == .@"enum") .string else .plain_if_safe);
}

/// Writes a dataset as parsed, for the datasets a sync leaves alone.
fn writeParsedDataset(w: *Io.Writer, d: yaml.Dataset) Io.Writer.Error!void {
    try yaml.writeScalar(w, d.name, .string);
    if (d.records.len == 0) return w.writeAll(": []\n");
    try w.writeAll(":\n");
    for (d.records) |rec| {
        for (rec.fields, 0..) |f, i| {
            try w.writeAll(if (i == 0) "  - " else "    ");
            try yaml.writeScalar(w, f.key, .plain_if_safe);
            try w.writeAll(": ");
            try yaml.writeScalar(w, f.value, if (f.quoted) .quoted else .plain_if_safe);
            try w.writeByte('\n');
        }
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
    const S = zom.Schema(struct { id: u32, name: []const u8 }, "users", .id, .{});
    const original = "posts:\n  - id: 1\nusers:\n  - name: Ada\n    id: 1\n";
    try dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data = original });

    var gw = WritableGateway.init(allocator, .{ .io = testing.io, .dir = dir, .path = "data.yaml" });
    defer gw.deinit();
    const d = try gw.dataset(S);
    _ = try d.insert(.{ .id = 2, .name = "a \"quoted\" name" });
    gw.sync() catch |err| {
        const got = try dir.readFileAlloc(testing.io, "data.yaml", testing.allocator, .unlimited);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(original, got);
        try testing.expect(d.dirty);
        return err;
    };
    const got = try dir.readFileAlloc(testing.io, "data.yaml", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(
        \\posts:
        \\  - id: 1
        \\users:
        \\  - id: 1
        \\    name: Ada
        \\  - id: 2
        \\    name: a "quoted" name
        \\
    , got);
}
