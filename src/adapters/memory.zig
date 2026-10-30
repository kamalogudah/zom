//! In-memory adapter = rom-core's `ROM::Memory`.
//!
//! The gateway owns one dataset per relation name. Datasets copy string
//! attributes into their own arena on insert/update, so callers never have
//! to keep input buffers alive. Like a database table, a dataset rejects
//! writes that would duplicate the schema's primary key.

const std = @import("std");
const q = @import("../query.zig");
const Supports = @import("../adapter.zig").Supports;
const Allocator = std.mem.Allocator;

pub const Gateway = struct {
    pub const adapter_name = "memory";
    pub const Config = struct {};

    allocator: Allocator,
    datasets: std.StringHashMapUnmanaged(Entry) = .empty,

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
        return MemoryDataset(S);
    }

    pub fn dataset(self: *Gateway, comptime S: type) !*MemoryDataset(S) {
        const D = MemoryDataset(S);
        const gop = try self.datasets.getOrPut(self.allocator, S.name);
        if (gop.found_existing) {
            if (!std.mem.eql(u8, gop.value_ptr.type_name, @typeName(S)))
                return error.DatasetTypeMismatch;
            return @ptrCast(@alignCast(gop.value_ptr.ptr));
        }
        errdefer self.datasets.removeByPtr(gop.key_ptr);
        const d = try self.allocator.create(D);
        d.* = D.init(self.allocator);
        gop.value_ptr.* = .{ .ptr = d, .deinit_fn = D.deinitOpaque, .type_name = @typeName(S) };
        return d;
    }
};

pub fn MemoryDataset(comptime S: type) type {
    return struct {
        const Self = @This();
        const T = S.Tuple;
        const Q = q.Query(T);
        const pk = S.primary_key;

        /// Every query is evaluated here, in memory.
        pub const supports: Supports = .all;

        allocator: Allocator,
        arena: std.heap.ArenaAllocator,
        rows: std.ArrayList(T) = .empty,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator, .arena = std.heap.ArenaAllocator.init(allocator) };
        }

        pub fn deinit(self: *Self) void {
            self.rows.deinit(self.allocator);
            self.arena.deinit();
        }

        fn deinitOpaque(ptr: *anyopaque, allocator: Allocator) void {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.deinit();
            allocator.destroy(self);
        }

        pub fn insert(self: *Self, row: T) !T {
            const key = Q.fieldValue(row, pk);
            for (self.rows.items) |existing| {
                if (Q.fieldValue(existing, pk).eql(key)) return error.DuplicatePrimaryKey;
            }
            const owned = try self.dupeStrings(row);
            try self.rows.append(self.allocator, owned);
            return owned;
        }

        pub fn read(self: *Self, query: Q, allocator: Allocator) ![]T {
            var hits: std.ArrayList(T) = .empty;
            defer hits.deinit(allocator);
            for (self.rows.items) |row| {
                if (query.matches(row)) try hits.append(allocator, row);
            }
            if (query.order) |o| std.mem.sort(T, hits.items, o, Q.lessThan);
            const start = @min(query.offset, hits.items.len);
            const end = if (query.limit) |l| @min(start + l, hits.items.len) else hits.items.len;
            return allocator.dupe(T, hits.items[start..end]);
        }

        pub fn count(self: *Self, query: Q) !usize {
            var n: usize = 0;
            for (self.rows.items) |row| {
                if (query.matches(row)) n += 1;
            }
            return n;
        }

        /// Converts every change (copying strings once) into `patch` before
        /// touching a row, so a bad value, a key clash or running out of
        /// memory leaves the dataset unchanged. Applying cannot fail.
        pub fn update(self: *Self, query: Q, changes: []const Q.Change) !usize {
            var patch: T = undefined;
            for (changes) |c| try self.prepare(&patch, c);
            for (changes) |c| {
                if (c.field == pk) try self.checkKeyChange(query, c.value);
            }
            var n: usize = 0;
            for (self.rows.items) |*row| {
                if (!query.matches(row.*)) continue;
                for (changes) |c| apply(row, &patch, c.field);
                n += 1;
            }
            return n;
        }

        pub fn delete(self: *Self, query: Q) !usize {
            var kept: usize = 0;
            for (self.rows.items) |row| {
                if (!query.matches(row)) {
                    self.rows.items[kept] = row;
                    kept += 1;
                }
            }
            const removed = self.rows.items.len - kept;
            self.rows.shrinkRetainingCapacity(kept);
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
            for (self.rows.items) |row| {
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
