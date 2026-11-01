//! String ownership: who frees the strings in the tuples a read returns.
//!
//! The memory, CSV and YAML adapters hold their rows, so the strings they
//! hand back point into the dataset and live as long as the gateway. A
//! database adapter such as zom-pg holds no rows: each read copies its
//! strings out of the driver's buffers into the allocator passed to it, and
//! the caller frees them.
//!
//! A dataset says which it is with `pub const strings: zom.StringOwnership`
//! (`.dataset` when left out). Code that should run on any adapter frees a
//! read with the relation, which knows:
//!
//!     const rows = try users.toSlice(allocator);
//!     defer users.free(allocator, rows);
//!
//!     if (try users.byPk(1).one(allocator)) |u| {
//!         defer users.freeOne(allocator, u);
//!     }
//!
//! For a `.dataset` adapter, `free` is `allocator.free(rows)` and `freeOne`
//! does nothing, so the same code is correct on both.

const std = @import("std");
const q = @import("query.zig");

pub const StringOwnership = enum {
    /// Strings point into the dataset and stay valid while the gateway
    /// lives (and, for the memory store, until `clear`). The caller frees
    /// only the slice.
    dataset,
    /// Strings are allocated with the allocator passed to the read (or to
    /// `insert`). The caller frees each one, or uses an arena; the
    /// relation's `free` and `freeOne` do it.
    caller,
};

/// True when `F` (or its optional child) is a string attribute.
pub fn isStringField(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .optional => |o| q.isString(o.child),
        else => q.isString(F),
    };
}

/// True when `F` (or its optional child) is a string that `allocator.free`
/// can take: a slice, not a pointer to an array.
pub fn isFreeableString(comptime F: type) bool {
    const S = switch (@typeInfo(F)) {
        .optional => |o| o.child,
        else => F,
    };
    return q.isString(S) and @typeInfo(S).pointer.size == .slice;
}

/// The names of `T`'s fields, for `freeFields`' `keep`.
pub fn fieldNames(comptime T: type) []const []const u8 {
    const fields = @typeInfo(T).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, &names) |f, *n| n.* = f.name;
    const final = names;
    return &final;
}

/// Frees every string attribute of `item` with `allocator`, except those
/// named in `keep` (whose strings now belong to something else, e.g. a
/// narrower struct mapped from `item`). Null optionals are skipped.
pub fn freeFields(comptime T: type, allocator: std.mem.Allocator, item: T, comptime keep: []const []const u8) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (comptime !isStringField(f.type) or contains(keep, f.name)) continue;
        if (comptime !isFreeableString(f.type))
            @compileError("zom: '" ++ f.name ++ "' of " ++ @typeName(T) ++ " is `" ++ @typeName(f.type) ++
                "`; caller-owned strings must be slices such as []const u8");
        switch (@typeInfo(f.type)) {
            .optional => if (@field(item, f.name)) |s| allocator.free(s),
            else => allocator.free(@field(item, f.name)),
        }
    }
}

/// Frees the strings of every item, then the slice.
pub fn freeAll(comptime T: type, allocator: std.mem.Allocator, items: []const T) void {
    for (items) |item| freeFields(T, allocator, item, &.{});
    allocator.free(items);
}

/// Copies every string attribute of `item` into `allocator`. On failure the
/// copies made so far are freed.
pub fn dupeFields(comptime T: type, allocator: std.mem.Allocator, item: T) error{OutOfMemory}!T {
    var out = item;
    const fields = @typeInfo(T).@"struct".fields;
    // Freed on error: the strings of `out` copied so far.
    var done: usize = 0;
    errdefer inline for (fields, 0..) |f, i| {
        if (comptime isStringField(f.type)) {
            if (i < done) switch (@typeInfo(f.type)) {
                .optional => if (@field(out, f.name)) |s| allocator.free(s),
                else => allocator.free(@field(out, f.name)),
            };
        }
    };
    inline for (fields, 0..) |f, i| {
        if (comptime isStringField(f.type)) {
            switch (@typeInfo(f.type)) {
                .optional => |o| if (@field(item, f.name)) |s| {
                    @field(out, f.name) = try dupe(o.child, allocator, s);
                },
                else => @field(out, f.name) = try dupe(f.type, allocator, @field(item, f.name)),
            }
        }
        done = i + 1;
    }
    return out;
}

fn dupe(comptime S: type, allocator: std.mem.Allocator, s: S) error{OutOfMemory}!S {
    if (comptime !isFreeableString(S))
        @compileError("zom: caller-owned strings must be slices such as []const u8, found `" ++ @typeName(S) ++ "`");
    if (comptime @typeInfo(S).pointer.sentinel() != null) return allocator.dupeZ(u8, s);
    return allocator.dupe(u8, s);
}

fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "freeFields frees strings except the kept ones" {
    const T = struct { id: u32, name: []const u8, note: ?[]const u8 };
    const a = std.testing.allocator;
    const row = try dupeFields(T, a, .{ .id = 1, .name = "ada", .note = "x" });
    freeFields(T, a, row, &.{"name"});
    a.free(row.name);

    const rows = try a.alloc(T, 2);
    rows[0] = try dupeFields(T, a, .{ .id = 1, .name = "a", .note = null });
    rows[1] = try dupeFields(T, a, .{ .id = 2, .name = "b", .note = "n" });
    freeAll(T, a, rows);
}

test "dupeFields frees its copies when it runs out of memory" {
    const T = struct { a: []const u8, b: ?[]const u8, c: []const u8 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    try std.testing.expectError(error.OutOfMemory, dupeFields(T, failing.allocator(), .{ .a = "1", .b = "2", .c = "3" }));
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
}
