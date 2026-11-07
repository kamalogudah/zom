//! Mappers = ROM's `ROM::Mapper` and `combine`.
//!
//! ROM keeps persistence tuples and domain objects apart. Here the tuple is
//! the schema struct and the entity is any struct you like; a mapper is a
//! comptime-generated function between the two. Renames replace ROM's
//! `attribute :full_name, from: :name`.

const std = @import("std");
const q = @import("query.zig");
const build_options = @import("build_options");
const field_mapper = @import("field_mapper.zig");

pub const Rename = struct { from: []const u8, to: []const u8 };
pub const Options = struct {
    renames: []const Rename = &.{},
};

/// A comptime mapper from `Src` to `Dst`: each `Dst` field takes the `Src`
/// field of the same name (or the one renamed to it), else its default.
/// `options` is the `opts` it was made with; `Combined.mapWith` reads it
/// to rebuild the mapper with the association field left for itself.
pub fn Mapper(comptime Src: type, comptime Dst: type, comptime opts: Options) type {
    return field_mapper.FieldMapper(Src, Dst, opts, &.{});
}

/// True when `M` is a `zom.Mapper`, not a hand-written mapper type.
pub fn isMapper(comptime M: type) bool {
    if (@typeInfo(M) != .@"struct") return false;
    if (!@hasDecl(M, "Input") or !@hasDecl(M, "Output") or !@hasDecl(M, "options")) return false;
    if (@TypeOf(M.options) != Options) return false;
    return M == Mapper(M.Input, M.Output, M.options);
}

pub const CombineOptions = struct {
    /// Slice field on the parent entity that receives the children.
    into: []const u8,
    parent_key: []const u8,
    child_key: []const u8,
};

/// Deprecated: use `Relation.combine`, e.g.
/// `users.combine(.posts, posts).mapTo(Author, allocator)`, which reads the
/// children with one `in` query and groups them in O(n + m). To be removed
/// in a later 0.x release; build with `-Dno-deprecated` to turn the calls
/// left into compile errors.
///
/// ROM's `users.combine(:posts)` for a has-many association, done on loaded
/// entities: each parent gets the children whose `child_key` equals its
/// `parent_key`, in O(n·m). Use an arena; the child slices are allocated per
/// parent.
pub fn combineMany(
    comptime opts: CombineOptions,
    allocator: std.mem.Allocator,
    parents: anytype,
    children: anytype,
) !void {
    if (build_options.no_deprecated)
        @compileError("zom.combineMany is deprecated: use relation.combine(.assoc, target).mapTo(E, allocator) " ++
            "(built with -Dno-deprecated)");
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
