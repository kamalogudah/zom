//! Mappers = ROM's `ROM::Mapper` and `combine`.
//!
//! ROM keeps persistence tuples and domain objects apart. Here the tuple is
//! the schema struct and the entity is any struct you like; a mapper is a
//! comptime-generated function between the two. Renames replace ROM's
//! `attribute :full_name, from: :name`.

const std = @import("std");
const q = @import("query.zig");

pub const Rename = struct { from: []const u8, to: []const u8 };
pub const Options = struct {
    renames: []const Rename = &.{},
    /// `Dst` fields the mapper leaves undefined for the caller to fill.
    /// `combine` uses it for the association field, which has no source
    /// attribute and needs no default.
    skip: []const []const u8 = &.{},
};

pub fn Mapper(comptime Src: type, comptime Dst: type, comptime opts: Options) type {
    return struct {
        pub const Input = Src;
        pub const Output = Dst;
        pub const options = opts;

        /// The `Src` fields copied into `Dst`, e.g. to know which strings
        /// the output now shares with the input.
        pub const sources: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            for (@typeInfo(Dst).@"struct".fields) |f| {
                if (skipped(f.name)) continue;
                const src_name = sourceName(f.name);
                if (@hasField(Src, src_name)) names = names ++ .{src_name};
            }
            break :blk names;
        };

        fn skipped(comptime name: []const u8) bool {
            for (opts.skip) |s| {
                if (std.mem.eql(u8, s, name)) return true;
            }
            return false;
        }

        fn sourceName(comptime name: []const u8) []const u8 {
            for (opts.renames) |r| {
                if (std.mem.eql(u8, r.to, name)) return r.from;
            }
            return name;
        }

        pub fn call(src: Src) Dst {
            var dst: Dst = undefined;
            inline for (@typeInfo(Dst).@"struct".fields) |f| {
                const src_name = comptime sourceName(f.name);
                if (comptime skipped(f.name)) {
                    // Left for the caller.
                } else if (comptime @hasField(Src, src_name)) {
                    @field(dst, f.name) = @field(src, src_name);
                } else if (comptime f.defaultValue() != null) {
                    @field(dst, f.name) = comptime f.defaultValue().?;
                } else {
                    @compileError("zom.Mapper: " ++ @typeName(Dst) ++ "." ++ f.name ++
                        " has no source attribute `" ++ src_name ++ "` and no default");
                }
            }
            return dst;
        }

        /// Caller owns the returned slice.
        pub fn many(allocator: std.mem.Allocator, srcs: []const Src) ![]Dst {
            const out = try allocator.alloc(Dst, srcs.len);
            for (srcs, out) |s, *d| d.* = call(s);
            return out;
        }
    };
}

pub const CombineOptions = struct {
    /// Slice field on the parent entity that receives the children.
    into: []const u8,
    parent_key: []const u8,
    child_key: []const u8,
};

/// ROM's `users.combine(:posts)` for a has-many association, done on loaded
/// entities: each parent gets the children whose `child_key` equals its
/// `parent_key`. Use an arena; the child slices are allocated per parent.
pub fn combineMany(
    comptime opts: CombineOptions,
    allocator: std.mem.Allocator,
    parents: anytype,
    children: anytype,
) !void {
    const Child = @typeInfo(@TypeOf(children)).pointer.child;
    for (parents) |*parent| {
        const key = q.toValue(@field(parent.*, opts.parent_key));
        var matched: std.ArrayList(Child) = .empty;
        errdefer matched.deinit(allocator);
        for (children) |child| {
            const ord = q.toValue(@field(child, opts.child_key)).order(key) orelse continue;
            if (ord == .eq) try matched.append(allocator, child);
        }
        @field(parent.*, opts.into) = try matched.toOwnedSlice(allocator);
    }
}
