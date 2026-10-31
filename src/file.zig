//! zom.file: the gateway and datasets that file adapters share. zom-csv and
//! zom-yaml are each a `Format` handed to `Gateway(Format, mode)`. The format
//! says how to turn file bytes into rows and rows back into bytes, and this
//! module does everything else:
//!
//! - finding the file for a dataset (`Config.path` is a directory or a file),
//! - reading it, up to `Config.max_file_bytes`, without a UTF-8 BOM,
//! - loading each dataset on its first `dataset(S)` into a
//!   `zom.memory.Store(S)`, once,
//! - the read-only and writable dataset types (`FileDataset`),
//! - `sync()`, which writes dirty datasets back atomically,
//! - `Diagnostic`, the one-line message a failed load or sync leaves.
//!
//! Writability is a second gateway type (`mode`), not a config flag:
//! capabilities are the declarations a dataset type has, and a runtime flag
//! cannot add or remove declarations.
//!
//! ## The Format contract
//!
//! A format is a struct with these declarations, checked when the gateway
//! type is built. Every missing one is listed in a single compile error.
//!
//! ```zig
//! pub const name = "csv";              // the adapter_name
//! pub const extension = ".csv";        // file name of a dataset in a directory
//! pub const layout: zom.file.Layout = .one_per_file;
//! pub const Config = struct {          // must have these fields, and may add its own
//!     io: std.Io, path: []const u8, dir: std.Io.Dir = .cwd(), max_file_bytes: usize = ...,
//! };
//! pub const WriteError = error{...};   // what `dump` fails with, besides error.WriteFailed
//!
//! // Optional: what a writable dataset keeps from `load` for `dump` (CSV: the
//! // header's column order). Without it, `load` returns `void`.
//! pub fn State(comptime S: type) type { ... }
//!
//! // Fills `store` from `ctx.bytes`. `ctx.bytes == null` means the file
//! // does not exist yet (writable gateways only): return an empty state.
//! pub fn load(comptime S: type, ctx: zom.file.LoadContext(@This()), store: *zom.memory.Store(S)) !State(S)
//!
//! // Writes the whole file for `ctx.rows`.
//! pub fn dump(comptime S: type, ctx: zom.file.DumpContext(@This(), S), w: *std.Io.Writer) WriteError!void
//! ```
//!
//! ## Finding the file
//!
//! - `path` is a directory: the dataset is `<path>/<S.name><extension>`.
//! - `path` is a file and `layout == .one_per_file`: it holds the dataset
//!   named after its stem only (`data/users.csv` holds `users`). Any other
//!   dataset is `error.NotFound`.
//! - `path` is a file and `layout == .all_in_file`: it holds every dataset,
//!   and the format finds `S.name` inside it (`ctx.all_in_file`).
//! - `path` does not exist: `error.NotFound`, except on a writable gateway
//!   when it ends in `extension`. That is then a file that `sync` creates.
//!
//! A missing dataset file is `error.NotFound` on a read-only gateway, and an
//! empty dataset on a writable one, created by the first `sync` after a write.
//!
//! ## Syncing (writable gateways)
//!
//! Per dirty dataset: `dump` writes into `<file>.tmp` in the same directory,
//! which is flushed, fsynced and closed, then renamed over `<file>`. A rename
//! within one file system is atomic, so a reader sees the old file or the new
//! one. The new file keeps the old one's permissions. On any error the temp
//! file is deleted, the original is untouched, and the dataset stays dirty, so
//! `sync` can be retried. With `.all_in_file`, the file is read again just
//! before writing and given to `dump` as `ctx.current`, so the format can keep
//! the datasets this gateway did not change.
//!
//! `deinit` does not sync: unsynced writes are dropped (writing can fail, and
//! `deinit` cannot return an error). One process should write a file at a
//! time: two syncing the same file share the temp file name.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const memory = @import("adapters/memory.zig");
const Supports = @import("adapter.zig").Supports;
const Query = @import("query.zig").Query;

/// What to do with a column or key in a file that matches no schema field.
/// A writable gateway always rejects them, because `sync` would drop them.
pub const Unknown = enum { reject, ignore };

pub const Mode = enum { read_only, writable };

/// What a `Config.path` naming a file holds. A directory always holds one
/// file per dataset.
pub const Layout = enum {
    /// One dataset, named after the file's stem (CSV).
    one_per_file,
    /// Every dataset, keyed by name inside the file (YAML).
    all_in_file,
};

/// What went wrong on the last failed load or sync, as one line of text. Zig
/// errors carry no data, so the gateway and the format write the details here.
pub const Diagnostic = struct {
    pub const max_len = 1024;

    buf: [max_len]u8 = undefined,
    len: usize = 0,

    pub fn message(d: *const Diagnostic) []const u8 {
        return d.buf[0..d.len];
    }

    /// Replaces the message. One that doesn't fit is cut and ends in `...`.
    pub fn set(d: *Diagnostic, comptime fmt: []const u8, args: anytype) void {
        var w: Io.Writer = .fixed(&d.buf);
        w.print(fmt, args) catch return d.truncated();
        d.len = w.end;
    }

    /// Starts a message listing several problems: the prefix `fmt` then
    /// each `add`ed item, separated by `;`. Clears the old message; `finish`
    /// sets the new one if anything was added, and leaves it empty if not.
    pub fn list(d: *Diagnostic, comptime fmt: []const u8, args: anytype) List {
        d.len = 0;
        var l: List = .{ .d = d, .w = .fixed(&d.buf) };
        l.w.print(fmt, args) catch {
            l.full = true;
        };
        return l;
    }

    pub const List = struct {
        d: *Diagnostic,
        w: Io.Writer,
        count: usize = 0,
        full: bool = false,

        pub fn add(l: *List, comptime fmt: []const u8, args: anytype) void {
            l.count += 1;
            if (l.full) return;
            l.w.writeAll(if (l.count == 1) " " else "; ") catch {
                l.full = true;
                return;
            };
            l.w.print(fmt, args) catch {
                l.full = true;
            };
        }

        /// Whether anything was added, and so the diagnostic holds a message.
        pub fn finish(l: *List) bool {
            if (l.count == 0) return false;
            if (l.full) {
                l.d.truncated();
            } else {
                l.d.len = l.w.end;
            }
            return true;
        }
    };

    fn truncated(d: *Diagnostic) void {
        @memcpy(d.buf[max_len - 3 ..], "...");
        d.len = max_len;
    }
};

/// What `Format.load` gets.
pub fn LoadContext(comptime Format: type) type {
    return struct {
        allocator: Allocator,
        config: *const Format.Config,
        /// The dataset's file, relative to `config.dir`, for messages.
        file: []const u8,
        /// The file's contents without a UTF-8 byte order mark. `null` when
        /// the file does not exist, which only a writable gateway allows.
        /// Freed after `load`: the store copies strings.
        bytes: ?[]const u8,
        /// The file holds every dataset (`Layout.all_in_file` and a file
        /// `path`), so `load` looks for the one named `S.name`.
        all_in_file: bool,
        /// A writable gateway: unknown fields must be rejected, and a dataset
        /// missing from an `all_in_file` file is empty rather than an error.
        writable: bool,
        /// Set it before returning an error. Start messages with `file`.
        diagnostic: *Diagnostic,
    };
}

/// What `Format.dump` gets.
pub fn DumpContext(comptime Format: type, comptime S: type) type {
    return struct {
        /// For scratch memory; nothing allocated should outlive `dump`.
        allocator: Allocator,
        config: *const Format.Config,
        file: []const u8,
        rows: []const S.Tuple,
        state: *const StateOf(Format, S),
        all_in_file: bool,
        /// `all_in_file` only: the file's contents now (without a BOM), or
        /// null when it does not exist yet. Keep the other datasets from it.
        current: ?[]const u8,
        /// Set it before returning an error to say more than the error name.
        diagnostic: *Diagnostic,
    };
}

/// What a writable dataset keeps from `Format.load` for `Format.dump`.
pub fn StateOf(comptime Format: type, comptime S: type) type {
    return if (@hasDecl(Format, "State")) Format.State(S) else void;
}

/// What `sync` can fail with.
pub fn SyncError(comptime Format: type) type {
    const base = Format.WriteError || Io.Writer.Error || Allocator.Error || Io.File.OpenError ||
        Io.File.Writer.Error || Io.File.SyncError || Io.Dir.RenameError;
    // An `all_in_file` sync reads the file before writing it.
    return if (Format.layout == .all_in_file) base || Io.Dir.ReadFileAllocError || error{FileTooBig} else base;
}

/// The gateway for `Format`. `.read_only` datasets have `read` and `count`;
/// `.writable` ones add `insert`, `insertMany`, `update`, `delete` and
/// `sync`, and the gateway has `sync`, which writes every dirty dataset.
pub fn Gateway(comptime Format: type, comptime mode: Mode) type {
    comptime checkFormat(Format);
    const writable = mode == .writable;
    return struct {
        const Self = @This();

        pub const adapter_name: []const u8 = Format.name;
        pub const Config = Format.Config;

        allocator: Allocator,
        config: Config,
        datasets: std.StringHashMapUnmanaged(Entry) = .empty,
        /// Set when `dataset` fails to load a file, or `sync` to write one.
        diagnostic: Diagnostic = .{},

        /// A type-erased `*Dataset(S)`, as in `zom.memory.Gateway`.
        const Entry = struct {
            ptr: *anyopaque,
            deinit_fn: *const fn (*anyopaque, Allocator) void,
            sync_fn: if (writable) *const fn (*anyopaque, *Diagnostic) SyncError(Format)!void else void,
            type_name: []const u8,
        };

        /// Records the config. Nothing is read until the first `dataset` call.
        pub fn init(allocator: Allocator, config: Config) Self {
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
            return FileDataset(S, Format, mode);
        }

        /// The dataset for `S`, loading its file the first time. A failed load
        /// is not remembered: the next call tries again.
        pub fn dataset(self: *Self, comptime S: type) !*Dataset(S) {
            const D = Dataset(S);
            if (self.datasets.get(S.name)) |entry| {
                if (!std.mem.eql(u8, entry.type_name, @typeName(S))) return error.DatasetTypeMismatch;
                return @ptrCast(@alignCast(entry.ptr));
            }

            const loc = try self.locate(S.name);
            // A writable dataset keeps the path, to sync to.
            defer if (!writable) self.allocator.free(loc.file);
            errdefer if (writable) self.allocator.free(loc.file);

            const d = try self.allocator.create(D);
            errdefer self.allocator.destroy(d);
            d.* = .{ .store = .init(self.allocator) };
            errdefer d.store.deinit();
            const state = try self.load(S, loc, &d.store);
            if (writable) {
                d.state = state;
                d.target = .{
                    .allocator = self.allocator,
                    .config = self.config,
                    .file = loc.file,
                    .all_in_file = loc.all_in_file,
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
        /// in `diagnostic`. That dataset and those not yet written stay
        /// dirty, and their files are unchanged.
        pub fn sync(self: *Self) SyncError(Format)!void {
            if (!writable) @compileError("zom-" ++ Format.name ++ ": Gateway is read-only and has no sync; use zom_" ++ Format.name ++ ".WritableGateway");
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

        fn syncFn(comptime D: type) *const fn (*anyopaque, *Diagnostic) SyncError(Format)!void {
            return struct {
                fn sync(ptr: *anyopaque, diagnostic: *Diagnostic) SyncError(Format)!void {
                    const d: *D = @ptrCast(@alignCast(ptr));
                    diagnostic.len = 0;
                    d.syncReporting(diagnostic) catch |err| {
                        // The format may have said more already.
                        if (diagnostic.len == 0) diagnostic.set("{s}: sync failed: {t}", .{ d.target.file, err });
                        return err;
                    };
                }
            }.sync;
        }

        /// Reads `loc.file` and hands it to `Format.load`.
        fn load(self: *Self, comptime S: type, loc: Location, store: *memory.Store(S)) !StateOf(Format, S) {
            const cfg = &self.config;
            const bytes: ?[]u8 = cfg.dir.readFileAlloc(cfg.io, loc.file, self.allocator, .limited(cfg.max_file_bytes)) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    if (writable) break :blk null;
                    self.diagnostic.set("{s}: no such file", .{loc.file});
                    return error.NotFound;
                },
                error.StreamTooLong => {
                    self.diagnostic.set("{s}: larger than max_file_bytes ({d})", .{ loc.file, cfg.max_file_bytes });
                    return error.FileTooBig;
                },
                else => |e| {
                    self.diagnostic.set("{s}: {t}", .{ loc.file, e });
                    return e;
                },
            };
            defer if (bytes) |b| self.allocator.free(b);

            return Format.load(S, .{
                .allocator = self.allocator,
                .config = cfg,
                .file = loc.file,
                .bytes = if (bytes) |b| withoutBom(b) else null,
                .all_in_file = loc.all_in_file,
                .writable = writable,
                .diagnostic = &self.diagnostic,
            }, store);
        }

        const Location = struct {
            /// Owned by the caller.
            file: []u8,
            all_in_file: bool,
        };

        /// Where dataset `name` lives (see "Finding the file").
        fn locate(self: *Self, name: []const u8) !Location {
            const cfg = &self.config;
            const kind: Io.File.Kind = if (cfg.dir.statFile(cfg.io, cfg.path, .{})) |st| st.kind else |err| switch (err) {
                // A writable gateway may create the file `sync` writes.
                error.FileNotFound => if (writable and std.mem.eql(u8, std.fs.path.extension(cfg.path), Format.extension)) .file else {
                    self.diagnostic.set("{s}: no such file or directory", .{cfg.path});
                    return error.NotFound;
                },
                else => |e| return e,
            };
            if (kind == .directory) {
                const file_name = try std.mem.concat(self.allocator, u8, &.{ name, Format.extension });
                if (std.mem.eql(u8, cfg.path, ".")) return .{ .file = file_name, .all_in_file = false };
                defer self.allocator.free(file_name);
                return .{ .file = try std.fs.path.join(self.allocator, &.{ cfg.path, file_name }), .all_in_file = false };
            }
            switch (Format.layout) {
                .all_in_file => {},
                .one_per_file => if (!std.mem.eql(u8, std.fs.path.stem(cfg.path), name)) {
                    self.diagnostic.set("{s}: holds the dataset '{s}', not '{s}'", .{ cfg.path, std.fs.path.stem(cfg.path), name });
                    return error.NotFound;
                },
            }
            return .{ .file = try self.allocator.dupe(u8, cfg.path), .all_in_file = Format.layout == .all_in_file };
        }
    };
}

/// The dataset type of `Gateway(Format, mode)` for schema `S`: a
/// `memory.Store(S)` holding the file's rows, with only the declarations
/// `mode` allows, so `zom.Relation` refuses writes on a read-only one at
/// compile time.
pub fn FileDataset(comptime S: type, comptime Format: type, comptime mode: Mode) type {
    return switch (mode) {
        .read_only => ReadOnlyDataset(S),
        .writable => WritableDataset(S, Format),
    };
}

fn ReadOnlyDataset(comptime S: type) type {
    return struct {
        const Self = @This();
        const Q = Query(S.Tuple);
        const Store = memory.Store(S);

        pub const supports: Supports = Store.supports;

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
fn Target(comptime Format: type) type {
    return struct {
        allocator: Allocator,
        /// A copy of the gateway's; what it borrows, it still borrows.
        config: Format.Config,
        /// Relative to `config.dir`. Owned by the dataset.
        file: []const u8,
        all_in_file: bool,
    };
}

fn WritableDataset(comptime S: type, comptime Format: type) type {
    return struct {
        const Self = @This();
        const T = S.Tuple;
        const Q = Query(T);
        const Store = memory.Store(S);

        pub const supports: Supports = Store.supports;

        store: Store,
        state: StateOf(Format, S) = undefined,
        target: Target(Format) = undefined,
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

        /// Writes the file, if anything changed since the load or the last
        /// sync. Atomic: on error the file is unchanged and the dataset stays
        /// dirty. The gateway's `sync` does this for every dataset and also
        /// leaves a message in its `diagnostic`.
        pub fn sync(self: *Self) SyncError(Format)!void {
            var diagnostic: Diagnostic = .{};
            return self.syncReporting(&diagnostic);
        }

        fn syncReporting(self: *Self, diagnostic: *Diagnostic) SyncError(Format)!void {
            if (!self.dirty) return;
            const t = &self.target;
            // Only an `all_in_file` format can fail with read errors.
            const current: ?[]u8 = if (comptime Format.layout != .all_in_file) null else if (!t.all_in_file) null else t.config.dir.readFileAlloc(t.config.io, t.file, t.allocator, .limited(t.config.max_file_bytes)) catch |err| switch (err) {
                error.FileNotFound => null,
                error.StreamTooLong => return error.FileTooBig,
                else => |e| return e,
            };
            defer if (current) |c| t.allocator.free(c);

            const ctx: DumpContext(Format, S) = .{
                .allocator = t.allocator,
                .config = &t.config,
                .file = t.file,
                .rows = self.store.rows(),
                .state = &self.state,
                .all_in_file = t.all_in_file,
                .current = if (current) |c| withoutBom(c) else null,
                .diagnostic = diagnostic,
            };
            try writeFileAtomic(SyncError(Format), t.config.io, t.config.dir, t.allocator, t.file, ctx, dumpBody);
            self.dirty = false;
        }

        fn dumpBody(ctx: DumpContext(Format, S), w: *Io.Writer) (Format.WriteError || Io.Writer.Error)!void {
            return Format.dump(S, ctx, w);
        }
    };
}

/// Writes `file` atomically: `body(ctx, writer)` fills `<file>.tmp` in the
/// same directory, which is flushed, fsynced, closed and then renamed over
/// `file`. On error the temp file is deleted and `file` is untouched.
fn writeFileAtomic(
    comptime E: type,
    io: Io,
    dir: Io.Dir,
    allocator: Allocator,
    file: []const u8,
    ctx: anytype,
    comptime body: anytype,
) E!void {
    const tmp = try std.mem.concat(allocator, u8, &.{ file, ".tmp" });
    defer allocator.free(tmp);

    // Keep the old file's mode, so a sync does not widen or narrow access.
    const permissions: Io.File.Permissions = if (dir.statFile(io, file, .{})) |st|
        modeBits(st.permissions)
    else |_|
        .default_file;

    const f = try dir.createFile(io, tmp, .{ .permissions = permissions });
    errdefer dir.deleteFile(io, tmp) catch {};
    {
        // Closed before the rename, which Windows requires.
        defer f.close(io);
        var buf: [8192]u8 = undefined;
        var fw = f.writer(io, &buf);
        body(ctx, &fw.interface) catch |err| switch (err) {
            error.WriteFailed => return fw.err orelse error.WriteFailed,
            else => |e| return e,
        };
        try fw.flush();
        try f.sync(io);
    }
    try dir.rename(tmp, dir, file, io);
}

/// `stat` reports the file type bits too; `createFile` wants only the mode.
fn modeBits(p: Io.File.Permissions) Io.File.Permissions {
    if (@hasDecl(Io.File.Permissions, "fromMode")) return .fromMode(p.toMode() & 0o7777);
    return p;
}

fn withoutBom(bytes: []const u8) []const u8 {
    const bom = "\xEF\xBB\xBF";
    return if (std.mem.startsWith(u8, bytes, bom)) bytes[bom.len..] else bytes;
}

// ---------------------------------------------------------------- for formats

pub fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".fields.len;
}

/// Field name to index, in declaration order.
pub fn fieldIndex(comptime T: type) std.StaticStringMap(usize) {
    const fields = @typeInfo(T).@"struct".fields;
    var kvs: [fields.len]struct { []const u8, usize } = undefined;
    for (fields, 0..) |f, i| kvs[i] = .{ f.name, i };
    return .initComptime(kvs);
}

/// A field a file must give: neither optional nor defaulted.
pub fn isRequired(comptime f: std.builtin.Type.StructField) bool {
    return @typeInfo(f.type) != .optional and f.defaultValue() == null;
}

// ---------------------------------------------------------------- contract

/// Checks `F` against the Format contract (see the module comment) and lists
/// every problem in one compile error.
pub fn checkFormat(comptime F: type) void {
    comptime {
        if (@typeInfo(F) != .@"struct")
            @compileError("zom.file: format '" ++ @typeName(F) ++ "' must be a struct, found " ++ @tagName(@typeInfo(F)));
        var problems: []const u8 = "";
        const decls = .{
            .{ "name", "pub const name: []const u8 (the adapter name)" },
            .{ "extension", "pub const extension: []const u8 (\".csv\")" },
            .{ "layout", "pub const layout: zom.file.Layout" },
            .{ "Config", "pub const Config = struct { io, path, dir, max_file_bytes, ... }" },
            .{ "WriteError", "pub const WriteError: type (the error set `dump` returns)" },
            .{ "load", "pub fn load(comptime S: type, zom.file.LoadContext(Format), *zom.memory.Store(S)) !State(S)" },
            .{ "dump", "pub fn dump(comptime S: type, zom.file.DumpContext(Format, S), *std.Io.Writer) WriteError!void" },
        };
        for (decls) |d| {
            if (!@hasDecl(F, d[0])) problems = problems ++ "\n  - missing `" ++ d[1] ++ "`";
        }
        if (@hasDecl(F, "layout") and @TypeOf(F.layout) != Layout)
            problems = problems ++ "\n  - `layout` must be a zom.file.Layout, found `" ++ @typeName(@TypeOf(F.layout)) ++ "`";
        if (@hasDecl(F, "WriteError") and (@TypeOf(F.WriteError) != type or @typeInfo(F.WriteError) != .error_set))
            problems = problems ++ "\n  - `WriteError` must be an error set";
        if (@hasDecl(F, "Config")) {
            if (@TypeOf(F.Config) != type or @typeInfo(F.Config) != .@"struct") {
                problems = problems ++ "\n  - `Config` must be a struct type";
            } else {
                const fields = .{ .{ "io", Io }, .{ "path", []const u8 }, .{ "dir", Io.Dir }, .{ "max_file_bytes", usize } };
                for (fields) |f| {
                    if (!@hasField(F.Config, f[0])) {
                        problems = problems ++ "\n  - `Config` has no field `" ++ f[0] ++ ": " ++ @typeName(f[1]) ++ "`";
                    } else if (@FieldType(F.Config, f[0]) != f[1]) {
                        problems = problems ++ "\n  - `Config." ++ f[0] ++ "` must be `" ++ @typeName(f[1]) ++ "`, found `" ++ @typeName(@FieldType(F.Config, f[0])) ++ "`";
                    }
                }
            }
        }
        for (.{ "State", "load", "dump" }) |name| {
            if (@hasDecl(F, name) and @typeInfo(@TypeOf(@field(F, name))) != .@"fn")
                problems = problems ++ "\n  - `" ++ name ++ "` must be a function";
        }
        if (problems.len > 0)
            @compileError("zom.file: format '" ++ @typeName(F) ++ "' does not satisfy the format contract:" ++ problems);
    }
}

test "writeFileAtomic: a body that fails midway leaves the original byte-for-byte unchanged" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "id,name\r\n1,\"Ada\"\r\n\xEF\xBB\xBF";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = original });

    const E = error{NullNotRepresentable} || Io.Writer.Error || Allocator.Error || Io.File.OpenError ||
        Io.File.Writer.Error || Io.File.SyncError || Io.Dir.RenameError;
    const Failing = struct {
        /// Writes more than the file writer buffers, so part of it reaches
        /// the temp file, then fails as an encoder would.
        fn body(_: void, w: *Io.Writer) (error{NullNotRepresentable} || Io.Writer.Error)!void {
            for (0..4) |_| try w.splatByteAll('x', 8192);
            return error.NullNotRepresentable;
        }
    };
    try testing.expectError(
        error.NullNotRepresentable,
        writeFileAtomic(E, testing.io, tmp.dir, testing.allocator, "users.csv", {}, Failing.body),
    );

    const got = try tmp.dir.readFileAlloc(testing.io, "users.csv", testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, original, got);
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "users.csv.tmp", .{}));
}

test "Diagnostic.list joins items, and is empty without one" {
    var d: Diagnostic = .{};
    d.set("before", .{});
    var none = d.list("{s}: problems:", .{"f"});
    try std.testing.expect(!none.finish());
    try std.testing.expectEqualStrings("", d.message());

    var l = d.list("{s}: problems:", .{"f"});
    l.add("one {d}", .{1});
    l.add("two", .{});
    try std.testing.expect(l.finish());
    try std.testing.expectEqualStrings("f: problems: one 1; two", d.message());

    var long = d.list("x", .{});
    for (0..300) |_| long.add("item", .{});
    try std.testing.expect(long.finish());
    try std.testing.expectEqual(Diagnostic.max_len, d.message().len);
    try std.testing.expect(std.mem.endsWith(u8, d.message(), "..."));
}
