//! Pagination: `relation.page(n).perPage(k)`.
//!
//!     const p = try users.order(.id, .asc).page(2).perPage(20).paginate(allocator);
//!     defer p.free(allocator);
//!     // p.rows: rows 21 to 40, p.total: every matching row, p.pages: ceil(total / 20)
//!
//! Pages start at 1. Page `n` of `k` is `offset((n - 1) * k).limit(k)` on
//! the relation, and `paginate` adds the total from `count()` on the same
//! query without its limit and offset. A `page` or `perPage` of 0 is a
//! compile error when it is comptime-known (a literal), and a panic
//! otherwise; `(n - 1) * k` past `usize` is `error.ValueOutOfRange`, from
//! the read.
//!
//! Every relation has `page`, rather than it being a schema plugin like
//! `timestamps`: plugins hook into the changesets (`beforeCreate`,
//! `beforeUpdate`), while pagination only composes `limit`, `offset` and
//! `count`, which every relation already has, and Zig has no way for a
//! plugin to add methods to the relation type.
//!
//! `paginate` makes two dataset calls, a count then a read, which may see
//! different rows if something writes in between; run it in a transaction
//! when that matters.

const std = @import("std");

/// What `paginate` returns. Free it with `free(allocator)`.
pub fn Result(comptime Rel: type) type {
    return struct {
        const Self = @This();

        /// The rows of this page: at most `per_page`, none past the end.
        rows: []Rel.Output,
        /// The rows of every page: the relation's count without paging.
        total: usize,
        page: usize,
        per_page: usize,
        /// `ceil(total / per_page)`, 0 when `total` is 0.
        pages: usize,

        /// Frees `rows` like the relation's `free`.
        pub fn free(self: Self, allocator: std.mem.Allocator) void {
            Rel.freeRows(allocator, self.rows);
        }
    };
}

/// What `relation.page(n)` returns: call `perPage(k)` on it.
pub fn Pager(comptime Rel: type) type {
    return struct {
        const Self = @This();

        relation: Rel,
        page: usize,

        /// `k` rows a page. 0 is a compile error when comptime-known, a
        /// panic otherwise.
        pub fn perPage(self: Self, k: anytype) Page(Rel) {
            return .{ .relation = self.relation, .page = self.page, .per_page = positive(Rel, k, "perPage") };
        }
    };
}

/// Page `page` of `per_page` rows of `relation`.
pub fn Page(comptime Rel: type) type {
    return struct {
        const Self = @This();

        /// The relation being paged, as it was before `page(n)`.
        relation: Rel,
        page: usize,
        per_page: usize,

        /// `(page - 1) * per_page`, or `error.ValueOutOfRange` when that
        /// does not fit in `usize`.
        pub fn offset(self: Self) error{ValueOutOfRange}!usize {
            return std.math.mul(usize, self.page - 1, self.per_page) catch error.ValueOutOfRange;
        }

        /// The relation with this page's offset and limit, replacing any it
        /// had.
        pub fn paged(self: Self) error{ValueOutOfRange}!Rel {
            return self.relation.offset(try self.offset()).limit(self.per_page);
        }

        /// This page's rows. Free them with the relation's `free`.
        pub fn toSlice(self: Self, allocator: std.mem.Allocator) ![]Rel.Output {
            return (try self.paged()).toSlice(allocator);
        }

        /// This page's rows and the total over every page. A page past the
        /// end has no rows, and the same total.
        pub fn paginate(self: Self, allocator: std.mem.Allocator) !Result(Rel) {
            const rel = try self.paged();
            var all = self.relation;
            all.query.limit = null;
            all.query.offset = 0;
            const total = if (comptime Rel.mode == .strict) try all.count() else try all.count(allocator);
            const rows = try rel.toSlice(allocator);
            return .{
                .rows = rows,
                .total = total,
                .page = self.page,
                .per_page = self.per_page,
                .pages = std.math.divCeil(usize, total, self.per_page) catch unreachable,
            };
        }
    };
}

/// `n` as a `usize`, which must be at least 1: a compile error for a
/// comptime-known `n` below that, a panic for a runtime one.
pub fn positive(comptime Rel: type, n: anytype, comptime call: []const u8) usize {
    if (@TypeOf(n) == comptime_int) {
        if (n < 1)
            @compileError(std.fmt.comptimePrint("zom: `{s}({d})` on relation '{s}': pages and page sizes start at 1", .{ call, n, Rel.schema.name }));
        return n;
    }
    const v: usize = n;
    if (v == 0) std.debug.panic("zom: `{s}(0)` on relation '{s}': pages and page sizes start at 1", .{ call, Rel.schema.name });
    return v;
}
