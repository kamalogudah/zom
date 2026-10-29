//! In-memory adapter = rom-core's `ROM::Memory`.
//!
//! The gateway owns one dataset per relation name. Datasets copy string
//! attributes into their own arena on insert/update, so callers never have
//! to keep input buffers alive. Like a database table, a dataset rejects
//! writes that would duplicate the schema's primary key.

const std = @import("std");
const q = @import("../query.zig");
const Allocator = std.mem.Allocator;

pub const Gateway = struct {
    allocator: Allocator,
    datasets: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        ptr: *anyopaque,
        deinit_fn: *const fn (*anyopaque, Allocator) void,
        type_name: []const u8,
    };

    pub fn init(allocator: Allocator) Gateway {
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

        pub fn count(self: *Self, query: Q) usize {
            var n: usize = 0;
            for (self.rows.items) |row| {
                if (query.matches(row)) n += 1;
            }
            return n;
        }

        /// Checks every change before touching a row, so a bad value or a key
        /// clash leaves the dataset unchanged.
        pub fn update(self: *Self, query: Q, changes: []const Q.Change) !usize {
            for (changes) |c| {
                try validate(c);
                if (c.field == pk) try self.checkKeyChange(query, c.value);
            }
            var n: usize = 0;
            for (self.rows.items) |*row| {
                if (!query.matches(row.*)) continue;
                for (changes) |c| try self.apply(row, c);
                n += 1;
            }
            return n;
        }

        pub fn delete(self: *Self, query: Q) usize {
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

        fn validate(change: Q.Change) !void {
            switch (change.field) {
                inline else => |tag| _ = try q.fromValue(@FieldType(T, @tagName(tag)), change.value),
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

        fn apply(self: *Self, row: *T, change: Q.Change) !void {
            switch (change.field) {
                inline else => |tag| {
                    const F = @FieldType(T, @tagName(tag));
                    var v = change.value;
                    if (v == .string) v = .{ .string = try self.arena.allocator().dupe(u8, v.string) };
                    @field(row, @tagName(tag)) = try q.fromValue(F, v);
                },
            }
        }

        fn dupeStrings(self: *Self, row: T) !T {
            const a = self.arena.allocator();
            var out = row;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (f.type == []const u8) {
                    @field(out, f.name) = try a.dupe(u8, @field(row, f.name));
                } else if (f.type == ?[]const u8) {
                    if (@field(row, f.name)) |s| @field(out, f.name) = try a.dupe(u8, s);
                }
            }
            return out;
        }
    };
}
