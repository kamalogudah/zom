//! In-memory adapter = rom-core's `ROM::Memory`.
//!
//! `Store(S)` is the row engine: rows, string arena, filtering, sorting and
//! primary-key checks. It needs no gateway, so file adapters (CSV, YAML)
//! wrap it to hold the rows they load. `Gateway` owns one `Store` per
//! relation name and hands it out as its dataset.

const std = @import("std");
const q = @import("../query.zig");
const Supports = @import("../adapter.zig").Supports;
const Allocator = std.mem.Allocator;

pub const Gateway = struct {
    pub const adapter_name = "memory";
    pub const Config = struct {};

    allocator: Allocator,
    datasets: std.StringHashMapUnmanaged(Entry) = .empty,

    /// A type-erased `*Store(S)`, so stores of different schemas share
    /// one map. `type_name` catches two schemas with the same name.
    const Entry = struct {
        ptr: *anyopaque,
        deinit_fn: *const fn (*anyopaque, Allocator) void,
        type_name: []const u8,
    };

    pub fn init(allocator: Allocator, _: Config) Gateway {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Gateway) void {
        var it = self.datasets.valueIterator();
        while (it.next()) |entry| entry.deinit_fn(entry.ptr, self.allocator);
        self.datasets.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn Dataset(comptime S: type) type {
        return Store(S);
    }

    pub fn dataset(self: *Gateway, comptime S: type) !*Store(S) {
        const D = Store(S);
        const gop = try self.datasets.getOrPut(self.allocator, S.name);
        if (gop.found_existing) {
            if (!std.mem.eql(u8, gop.value_ptr.type_name, @typeName(S)))
                return error.DatasetTypeMismatch;
            return @ptrCast(@alignCast(gop.value_ptr.ptr));
        }
        errdefer self.datasets.removeByPtr(gop.key_ptr);
        const d = try self.allocator.create(D);
        d.* = D.init(self.allocator);
        gop.value_ptr.* = .{ .ptr = d, .deinit_fn = destroyFn(D), .type_name = @typeName(S) };
        return d;
    }

    fn destroyFn(comptime D: type) *const fn (*anyopaque, Allocator) void {
        return struct {
            fn destroy(ptr: *anyopaque, allocator: Allocator) void {
                const d: *D = @ptrCast(@alignCast(ptr));
                d.deinit();
                allocator.destroy(d);
            }
        }.destroy;
    }
};

/// The in-memory row engine for schema `S`, and the memory gateway's dataset.
///
/// Like a database table it rejects an `insert`, `insertMany` or `update`
/// that would duplicate the primary key. `load` and `loadMany` skip that
/// check for rows the caller already trusts, such as a file being read.
///
/// String lifetime: every string attribute is copied into the store's arena
/// on the way in, so callers never have to keep input buffers alive. Rows
/// handed back by `read` and `rows` point into that arena and stay valid
/// until `clear` or `deinit`. Strings replaced by `update` or dropped by
/// `delete` are not freed before then either.
///
/// Rows are kept in insertion order. Treat the fields as private and use
/// the methods.
pub fn Store(comptime S: type) type {
    return struct {
        const Self = @This();
        const T = S.Tuple;
        const Q = q.Query(T);
        const pk = S.primary_key;

        /// Every query is evaluated here, in memory.
        pub const supports: Supports = .all;

        allocator: Allocator,
        arena: std.heap.ArenaAllocator,
        list: std.ArrayList(T) = .empty,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
            self.arena.deinit();
            self.* = undefined;
        }

        /// Every stored row, in insertion order, for adapters that write the
        /// whole table out (CSV sync). The slice is invalidated by the next
        /// write; its strings live until `clear` or `deinit`.
        pub fn rows(self: *const Self) []const T {
            return self.list.items;
        }

        /// Drops every row and frees every copied string, keeping the
        /// memory for reuse. Rows read earlier must not be used afterwards.
        pub fn clear(self: *Self) void {
            self.list.clearRetainingCapacity();
            _ = self.arena.reset(.retain_capacity);
        }

        /// Stores `row`, copying its strings, and returns the stored copy.
        /// `error.DuplicatePrimaryKey` if its key is taken.
        pub fn insert(self: *Self, row: T) !T {
            if (self.hasKey(Q.fieldValue(row, pk))) return error.DuplicatePrimaryKey;
            return self.load(row);
        }

        /// `insert` without the primary-key check, for bulk loads from a
        /// source that is already unique. Loading a duplicate key is not
        /// detected, and later key lookups may then see either row.
        pub fn load(self: *Self, row: T) !T {
            try self.list.ensureUnusedCapacity(self.allocator, 1);
            const owned = try self.dupeStrings(row);
            self.list.appendAssumeCapacity(owned);
            return owned;
        }

        /// `insertMany` without the primary-key checks. All or nothing on
        /// running out of memory, like `insertMany`.
        pub fn loadMany(self: *Self, batch: []const T) !usize {
            try self.list.ensureUnusedCapacity(self.allocator, batch.len);
            const old_len = self.list.items.len;
            errdefer self.list.shrinkRetainingCapacity(old_len);
            for (batch) |row| self.list.appendAssumeCapacity(try self.dupeStrings(row));
            return batch.len;
        }

        /// All or nothing: every key is checked, against the stored rows and
        /// against the rest of the batch, and the row capacity is reserved
        /// before anything is stored. If copying a string then runs out of
        /// memory, the rows appended so far are dropped again. Strings
        /// already copied stay in the arena until `clear` or `deinit`, as
        /// with `update`, so there is nothing else to undo.
        pub fn insertMany(self: *Self, batch: []const T) !usize {
            for (batch, 0..) |row, i| {
                const key = Q.fieldValue(row, pk);
                if (self.hasKey(key)) return error.DuplicatePrimaryKey;
                for (batch[0..i]) |earlier| {
                    if (Q.fieldValue(earlier, pk).eql(key)) return error.DuplicatePrimaryKey;
                }
            }
            return self.loadMany(batch);
        }

        fn hasKey(self: *const Self, key: q.Value) bool {
            for (self.list.items) |existing| {
                if (Q.fieldValue(existing, pk).eql(key)) return true;
            }
            return false;
        }

        /// The matching rows, sorted and paged, in a slice the caller frees
        /// with `allocator`. Their strings still belong to the store.
        pub fn read(self: *Self, query: Q, allocator: Allocator) ![]T {
            var hits: std.ArrayList(T) = .empty;
            defer hits.deinit(allocator);
            for (self.list.items) |row| {
                if (query.matches(row)) try hits.append(allocator, row);
            }
            if (query.order) |o| std.mem.sort(T, hits.items, o, Q.lessThan);
            const start = @min(query.offset, hits.items.len);
            const end = if (query.limit) |l| @min(start + l, hits.items.len) else hits.items.len;
            return allocator.dupe(T, hits.items[start..end]);
        }

        /// The number of rows `read` would return: `limit` and `offset`
        /// apply, as with SQL's `count(*)` over a limited subquery.
        pub fn count(self: *Self, query: Q) !usize {
            var n: usize = 0;
            for (self.list.items) |row| {
                if (query.matches(row)) n += 1;
            }
            const rest = n - @min(query.offset, n);
            return if (query.limit) |l| @min(l, rest) else rest;
        }

        /// Converts every change (copying strings once) into `patch` before
        /// touching a row, so a bad value, a key clash or running out of
        /// memory leaves the store unchanged. Applying cannot fail.
        pub fn update(self: *Self, query: Q, changes: []const Q.Change) !usize {
            var patch: T = undefined;
            for (changes) |c| try self.prepare(&patch, c);
            for (changes) |c| {
                if (c.field == pk) try self.checkKeyChange(query, c.value);
            }
            var n: usize = 0;
            for (self.list.items) |*row| {
                if (!query.matches(row.*)) continue;
                for (changes) |c| apply(row, &patch, c.field);
                n += 1;
            }
            return n;
        }

        pub fn delete(self: *Self, query: Q) !usize {
            var kept: usize = 0;
            for (self.list.items) |row| {
                if (!query.matches(row)) {
                    self.list.items[kept] = row;
                    kept += 1;
                }
            }
            const removed = self.list.items.len - kept;
            self.list.shrinkRetainingCapacity(kept);
            return removed;
        }

        /// Writes the change's typed value into `patch`, checking its range
        /// and copying strings into the arena. A copy left unused because a
        /// later change fails is freed with the arena.
        fn prepare(self: *Self, patch: *T, change: Q.Change) !void {
            switch (change.field) {
                inline else => |tag| {
                    const F = @FieldType(T, @tagName(tag));
                    @field(patch, @tagName(tag)) = try ownedValue(F, self.arena.allocator(), change.value);
                },
            }
        }

        /// Setting the key is only valid for at most one row, and the new
        /// key must not belong to any row outside the update.
        fn checkKeyChange(self: *Self, query: Q, key: q.Value) !void {
            var matched: usize = 0;
            for (self.list.items) |row| {
                if (query.matches(row)) {
                    matched += 1;
                } else if (Q.fieldValue(row, pk).eql(key)) {
                    return error.DuplicatePrimaryKey;
                }
            }
            if (matched > 1) return error.DuplicatePrimaryKey;
        }

        fn apply(row: *T, patch: *const T, field: Q.Field) void {
            switch (field) {
                inline else => |tag| @field(row, @tagName(tag)) = @field(patch, @tagName(tag)),
            }
        }

        fn dupeStrings(self: *Self, row: T) !T {
            const a = self.arena.allocator();
            var out = row;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                switch (@typeInfo(f.type)) {
                    .optional => |o| if (comptime q.isString(o.child)) {
                        if (@field(row, f.name)) |s| @field(out, f.name) = try dupeString(o.child, a, s);
                    },
                    else => if (comptime q.isString(f.type)) {
                        @field(out, f.name) = try dupeString(f.type, a, @field(row, f.name));
                    },
                }
            }
            return out;
        }
    };
}

/// Like `q.fromValue`, but a string is copied into `a` as the attribute's
/// exact type, so the row never points at the caller's buffer.
fn ownedValue(comptime F: type, a: Allocator, v: q.Value) !F {
    return switch (@typeInfo(F)) {
        .optional => |o| if (v == .null) null else try ownedValue(o.child, a, v),
        else => if (comptime q.isString(F)) dupeString(F, a, v.string) else q.fromValue(F, v),
    };
}

/// Copies `s` into `a` as the string type `S`, keeping any sentinel.
///
/// Pointers to arrays (`*const [N]u8`) are rejected: the length is part of
/// the type, so an update with a runtime string could not be stored without
/// a length check that fails at runtime. Such fields are almost always
/// string literals, which are static anyway; use `[]const u8` instead.
fn dupeString(comptime S: type, a: Allocator, s: []const u8) Allocator.Error!S {
    const p = @typeInfo(S).pointer;
    if (p.size != .slice)
        @compileError("zom: string attributes of type " ++ @typeName(S) ++ " are not supported, use []const u8");
    if (p.sentinel()) |end| {
        const buf = try a.allocSentinel(u8, s.len, end);
        @memcpy(buf, s);
        return buf;
    }
    return a.dupe(u8, s);
}
