//! How a zom query becomes TigerBeetle reads. This file only plans; the
//! gateway sends the requests (gateway.zig, `TbDataset.scan`).
//!
//! | zom                                        | TigerBeetle                       |
//! |--------------------------------------------|-----------------------------------|
//! | `byPk(id)`, `where(.id, .in, ids)`         | `lookup_accounts` / `_transfers`  |
//! | `.eq` on `user_data_128/64/32`, `ledger`,  | `query_accounts` / `_transfers`,  |
//! |   `code`; `timestamp` ranges               |   one `QueryFilter`               |
//! | `.order(.timestamp, .desc)`                | the filter's `reversed` flag      |
//! | `.limit(n)`                                | the filter's `limit`, paged       |
//!
//! Anything else is not `filterable` / `orderable`: a compile error on a
//! strict relation, evaluated in memory on a `.fallback` one. `offset` is
//! unsupported too (`supports.offset = false`): TigerBeetle can't skip
//! rows, only start from a timestamp.
//!
//! The plan only narrows. Every row the cluster returns is checked against
//! the whole query (`Query.matches`), so a filter TigerBeetle can't express
//! exactly is still right, only slower. That covers the values a
//! `QueryFilter` can't hold: `user_data_128 = 0` (zero turns that filter
//! off), a float, or a second `eq` on the same field. A query that provably
//! matches nothing (`ledger = 1 AND ledger = 2`, an empty timestamp range,
//! an id that isn't a `u128`) sends nothing at all.

const std = @import("std");
const zom = @import("zom");
const tb = @import("tb.zig");
const c = tb.c;

/// The most records one `query_*` reply holds, on every release build:
/// the cluster caps `limit` at what fits a message body (1 MiB), and,
/// unlike requests, replies are not cut by a `--development` cluster's
/// smaller `batch_size_limit` (tigerbeetle src/state_machine.zig,
/// `prefetch_query_*`). So a page shorter than the limit asked for is the
/// last one.
pub const query_max: u32 = 8189;

/// The attributes `query_*` filters on by equality, as named in both
/// `tb.Account`, `tb.Transfer` and `tb_query_filter_t`. The
/// `tb_account_filter_t` of `get_account_*` has them all but `ledger`.
pub const query_fields = [_][]const u8{ "user_data_128", "user_data_64", "user_data_32", "ledger", "code" };

/// The dataset's `filterable` (see adapter.zig): which `field op ...`
/// filters TigerBeetle evaluates.
pub fn filterable(comptime field: []const u8, comptime op: zom.Op) bool {
    if (eql(field, "id")) return op == .eq or op == .in;
    if (eql(field, "timestamp")) return switch (op) {
        .eq, .lt, .lte, .gt, .gte, .between => true,
        else => false,
    };
    for (query_fields) |f| {
        if (eql(field, f)) return op == .eq;
    }
    return false;
}

/// The dataset's `orderable`: `query_*` returns rows by `timestamp`,
/// ascending or (`reversed`) descending, and by nothing else.
pub fn orderable(comptime field: []const u8) bool {
    return eql(field, "timestamp");
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return comptime std.mem.eql(u8, a, b);
}

/// Most ids one lookup sends: a query's `in` holds at most `max_in`.
pub const lookup_max = zom.Query(tb.Account).max_in;

comptime {
    // A lookup is always one request: 64 ids are far below the smallest
    // request a cluster accepts (4 KiB), and 64 records below a reply.
    std.debug.assert(lookup_max == zom.Query(tb.Transfer).max_in);
    std.debug.assert(lookup_max * @sizeOf(u128) <= 4096);
    std.debug.assert(lookup_max <= query_max);
}

/// The requests one read sends.
pub const Plan = struct {
    source: Source,
    /// The rows come back in another order than the query's: sort them in
    /// memory (all of them, so no early stop at the limit). True for a
    /// lookup with an order, and for an order not led by `timestamp`.
    sort: bool = false,

    pub const Source = union(enum) {
        /// Nothing can match: send nothing.
        none,
        /// `lookup_*` these ids, in this order, each once.
        lookup: Ids,
        /// `query_*` with this filter; `limit` is set per page.
        query: c.tb_query_filter_t,
    };
};

pub const Ids = struct {
    buf: [lookup_max]u128 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Ids) []const u128 {
        return self.buf[0..self.len];
    }

    fn add(self: *Ids, id: u128) void {
        for (self.slice()) |have| if (have == id) return;
        std.debug.assert(self.len < lookup_max);
        self.buf[self.len] = id;
        self.len += 1;
    }
};

/// The plan for `query`. Only its top-level filters are looked at (the
/// rest is left to `Query.matches`), so any query has a plan.
pub fn plan(comptime T: type, query: *const zom.Query(T)) Plan {
    const orders = query.orderSlice();
    // The id filter with the fewest ids picks the rows; the others, and
    // every other filter, are checked on what the lookup returns.
    if (idsOf(T, query, .id)) |ids| {
        if (ids.len == 0) return .{ .source = .none };
        return .{ .source = .{ .lookup = ids }, .sort = orders.len > 0 };
    }

    var filter = std.mem.zeroes(c.tb_query_filter_t);
    if (!fillFilter(c.tb_query_filter_t, T, query, &filter)) return .{ .source = .none };
    if (descending(T, query)) filter.flags = c.TB_QUERY_FILTER_REVERSED;
    return .{ .source = .{ .query = filter }, .sort = sorts(T, query) };
}

/// The ids of the top-level `field` filter (`eq` or `in`) with the fewest,
/// each once, in the order given; null when there is no such filter. Ids
/// that aren't a `u128` are dropped, so the result may be empty: then
/// nothing matches.
pub fn idsOf(comptime T: type, query: *const zom.Query(T), comptime field: zom.Query(T).Field) ?Ids {
    const Q = zom.Query(T);
    var best: ?Q.Filter = null;
    var it = query.topNodes();
    while (it.next()) |i| {
        const f = topFilter(T, query, i) orelse continue;
        if (f.field != field) continue;
        switch (f.op) {
            .eq, .in => if (best == null or idCount(best.?) > idCount(f)) {
                best = f;
            },
            else => {},
        }
    }
    const f = best orelse return null;
    var ids: Ids = .{};
    switch (f.operand) {
        .one => |v| if (toInt(u128, v)) |id| ids.add(id),
        .many => |list| for (0..list.len) |i| {
            if (toInt(u128, list.at(i))) |id| ids.add(id);
        },
        else => unreachable, // `eq` and `in` carry one value or a list
    }
    return ids;
}

/// The `get_account_transfers` / `get_account_balances` filter for one
/// account: `sides` is `TB_ACCOUNT_FILTER_DEBITS`, `_CREDITS` or both,
/// and `query`'s top-level `eq` on `user_data_128/64/32` and `code`, its
/// timestamp range and a `timestamp` desc order narrow it as for `plan`.
/// Null when nothing can match. `limit` is set per page.
pub fn accountFilter(comptime T: type, query: *const zom.Query(T), account_id: u128, sides: u32) ?c.tb_account_filter_t {
    var filter = std.mem.zeroes(c.tb_account_filter_t);
    filter.account_id = account_id;
    if (!fillFilter(c.tb_account_filter_t, T, query, &filter)) return null;
    filter.flags = sides | if (descending(T, query)) @as(u32, c.TB_ACCOUNT_FILTER_REVERSED) else 0;
    return filter;
}

/// True when `query`'s order isn't led by `timestamp`, which is the only
/// order TigerBeetle returns rows in: they must be sorted in memory.
pub fn sorts(comptime T: type, query: *const zom.Query(T)) bool {
    const orders = query.orderSlice();
    return orders.len > 0 and orders[0].field != .timestamp;
}

fn descending(comptime T: type, query: *const zom.Query(T)) bool {
    const orders = query.orderSlice();
    return orders.len > 0 and orders[0].field == .timestamp and orders[0].direction == .desc;
}

/// Sets `filter`'s (a `tb_query_filter_t` or `tb_account_filter_t`)
/// equality fields and timestamp range from `query`'s top-level filters,
/// for every field both `T` and the filter have. False when they provably
/// match nothing.
fn fillFilter(comptime F: type, comptime T: type, query: *const zom.Query(T), filter: *F) bool {
    const Q = zom.Query(T);
    // The timestamp range, inclusive. Filters take 1 ..= maxInt(u63), with
    // 0 meaning no bound.
    var lo: i129 = 1;
    var hi: i129 = std.math.maxInt(u63);
    var it = query.topNodes();
    while (it.next()) |i| {
        const f = topFilter(T, query, i) orelse continue;
        if (f.field == .timestamp) {
            const range = timestampRange(f) orelse continue;
            lo = @max(lo, range[0]);
            hi = @min(hi, range[1]);
            continue;
        }
        inline for (query_fields) |name| {
            if (comptime @hasField(T, name) and @hasField(F, name)) {
                if (f.field == @field(Q.Field, name) and f.op == .eq) {
                    const v = f.operand.one;
                    // A float: left to `matches`.
                    if (isInteger(v)) {
                        // An integer the field can't hold matches no row.
                        const want = toInt(@FieldType(F, name), v) orelse return false;
                        // 0 turns the filter off, so it is left to `matches`.
                        if (want != 0) {
                            const have = &@field(filter, name);
                            if (have.* != 0 and have.* != want) return false;
                            have.* = want;
                        }
                    }
                }
            }
        }
    }
    if (lo > hi) return false;
    filter.timestamp_min = if (lo <= 1) 0 else @intCast(lo);
    filter.timestamp_max = if (hi >= std.math.maxInt(u63)) 0 else @intCast(hi);
    return true;
}

/// Node `i` when it is a top-level filter, else null (a group, which is
/// left to `matches`).
fn topFilter(comptime T: type, query: *const zom.Query(T), i: usize) ?zom.Query(T).Filter {
    return switch (query.nodes[i]) {
        .filter => |f| query.filters[f],
        else => null,
    };
}

fn idCount(f: anytype) usize {
    return if (f.operand == .many) f.operand.many.len else 1;
}

/// The timestamps filter `f` allows, inclusive, or null when it can't be
/// expressed as a range (left to `matches`). The bounds may be out of
/// TigerBeetle's range; `plan` clamps them.
fn timestampRange(f: anytype) ?[2]i129 {
    const none: [2]i129 = .{ 1, 0 }; // empty
    const min = std.math.minInt(i129);
    const max = std.math.maxInt(i129);
    switch (f.op) {
        .between => {
            const a, const b = f.operand.range;
            // A null bound is never true (see `Query.filterTruth`).
            if (a == .null or b == .null) return none;
            return .{ integer(a) orelse return null, integer(b) orelse return null };
        },
        .eq, .lt, .lte, .gt, .gte => {
            const v = integer(f.operand.one) orelse return if (f.operand.one == .null) none else null;
            return switch (f.op) {
                .eq => .{ v, v },
                .lt => .{ min, v - 1 },
                .lte => .{ min, v },
                .gt => .{ v + 1, max },
                .gte => .{ v, max },
                else => unreachable,
            };
        },
        else => return null,
    }
}

fn isInteger(v: zom.Value) bool {
    return integer(v) != null;
}

/// Every integer `Value` as an `i129`, which holds them all.
fn integer(v: zom.Value) ?i129 {
    return switch (v) {
        .int => |x| x,
        .uint => |x| x,
        .uint128 => |x| x,
        else => null,
    };
}

fn toInt(comptime F: type, v: zom.Value) ?F {
    return std.math.cast(F, integer(v) orelse return null);
}

/// Moves `filter`'s (a `tb_query_filter_t` or `tb_account_filter_t`)
/// timestamp range past `last`, the timestamp of the last row of a full
/// page, in the filter's direction. False when no timestamp is left in the
/// range, so there is no next page.
pub fn advance(filter: anytype, last: u64) bool {
    const reversed: u32 = switch (@TypeOf(filter.*)) {
        c.tb_query_filter_t => c.TB_QUERY_FILTER_REVERSED,
        c.tb_account_filter_t => c.TB_ACCOUNT_FILTER_REVERSED,
        else => |F| @compileError("advance: not a TigerBeetle filter: " ++ @typeName(F)),
    };
    std.debug.assert(last >= 1 and last <= std.math.maxInt(u63));
    if (filter.flags & reversed != 0) {
        if (last <= 1 or (filter.timestamp_min != 0 and last - 1 < filter.timestamp_min)) return false;
        filter.timestamp_max = last - 1;
    } else {
        if (last >= std.math.maxInt(u63) or (filter.timestamp_max != 0 and last + 1 > filter.timestamp_max)) return false;
        filter.timestamp_min = last + 1;
    }
    return true;
}

/// Rows `start..end` of `len` that `offset` and `limit` keep.
pub fn window(len: usize, offset: usize, limit: ?usize) struct { usize, usize } {
    const start = @min(offset, len);
    const end = if (limit) |l| start + @min(l, len - start) else len;
    return .{ start, end };
}

const testing = std.testing;
const QA = zom.Query(tb.Account);
const QT = zom.Query(tb.Transfer);

fn expectQuery(p: Plan) !c.tb_query_filter_t {
    try testing.expect(p.source == .query);
    return p.source.query;
}

test "filterable: id by eq and in, the indexed fields by eq, timestamp by range" {
    comptime {
        std.debug.assert(filterable("id", .eq) and filterable("id", .in));
        std.debug.assert(!filterable("id", .lt) and !filterable("id", .not_in));
        for (query_fields) |f| std.debug.assert(filterable(f, .eq) and !filterable(f, .neq) and !filterable(f, .gt));
        for ([_]zom.Op{ .eq, .lt, .lte, .gt, .gte, .between }) |op| std.debug.assert(filterable("timestamp", op));
        std.debug.assert(!filterable("timestamp", .neq) and !filterable("timestamp", .in));
        std.debug.assert(!filterable("amount", .eq) and !filterable("flags", .eq) and !filterable("debit_account_id", .eq));
        std.debug.assert(orderable("timestamp") and !orderable("id") and !orderable("amount"));
    }
}

test "byPk and id in become a lookup, ids deduplicated" {
    const one = plan(tb.Account, &(QA{}).where(.id, .eq, 7));
    try testing.expectEqualSlices(u128, &.{7}, one.source.lookup.slice());
    try testing.expect(!one.sort);

    const many = plan(tb.Account, &(QA{}).where(.id, .in, .{ 3, 1, 3, std.math.maxInt(u128) }).where(.ledger, .eq, 700));
    try testing.expectEqualSlices(u128, &.{ 3, 1, std.math.maxInt(u128) }, many.source.lookup.slice());

    // The smallest id filter picks the rows; any order is sorted in memory.
    const both = plan(tb.Account, &(QA{}).where(.id, .in, .{ 1, 2, 3 }).where(.id, .eq, 2).order(.timestamp, .desc));
    try testing.expectEqualSlices(u128, &.{2}, both.source.lookup.slice());
    try testing.expect(both.sort);

    // No id is a u128 (a literal like this is a compile error; a runtime
    // value isn't): nothing to send.
    var negative: i64 = -1;
    _ = &negative;
    try testing.expect(plan(tb.Account, &(QA{}).where(.id, .eq, negative)).source == .none);
}

test "indexed fields and timestamp ranges become one QueryFilter" {
    const f = try expectQuery(plan(tb.Transfer, &(QT{})
        .where(.ledger, .eq, 700)
        .where(.code, .eq, 10)
        .where(.user_data_128, .eq, std.math.maxInt(u128))
        .where(.user_data_64, .eq, 64)
        .where(.user_data_32, .eq, 32)
        .where(.timestamp, .gte, 100)
        .where(.timestamp, .lt, 200)));
    try testing.expectEqual(700, f.ledger);
    try testing.expectEqual(10, f.code);
    try testing.expectEqual(std.math.maxInt(u128), f.user_data_128);
    try testing.expectEqual(64, f.user_data_64);
    try testing.expectEqual(32, f.user_data_32);
    try testing.expectEqual(100, f.timestamp_min);
    try testing.expectEqual(199, f.timestamp_max);
    try testing.expectEqual(0, f.flags);

    const between = try expectQuery(plan(tb.Transfer, &(QT{}).where(.timestamp, .between, .{ 5, 9 }).where(.timestamp, .gt, 6)));
    try testing.expectEqual(7, between.timestamp_min);
    try testing.expectEqual(9, between.timestamp_max);
    const eq = try expectQuery(plan(tb.Transfer, &(QT{}).where(.timestamp, .eq, 42)));
    try testing.expectEqual(42, eq.timestamp_min);
    try testing.expectEqual(42, eq.timestamp_max);
}

test "order by timestamp desc is the reversed flag; other orders are sorted in memory" {
    const desc = plan(tb.Account, &(QA{}).order(.timestamp, .desc));
    try testing.expectEqual(@as(u32, c.TB_QUERY_FILTER_REVERSED), (try expectQuery(desc)).flags);
    try testing.expect(!desc.sort);
    const asc = plan(tb.Account, &(QA{}).order(.timestamp, .asc).order(.id, .desc));
    try testing.expectEqual(0, (try expectQuery(asc)).flags);
    try testing.expect(!asc.sort);
    try testing.expect(plan(tb.Account, &(QA{}).order(.ledger, .asc)).sort);
}

test "what a QueryFilter can't hold is left to matches; contradictions send nothing" {
    // 0 turns a filter off, so it can't be asked for: every row comes back
    // and `matches` keeps those with 0.
    const zero = try expectQuery(plan(tb.Account, &(QA{}).where(.user_data_64, .eq, 0)));
    try testing.expectEqual(0, zero.user_data_64);
    // No bound at all.
    const open = try expectQuery(plan(tb.Account, &(QA{}).where(.timestamp, .gte, 0).where(.timestamp, .lte, std.math.maxInt(u64))));
    try testing.expectEqual(0, open.timestamp_min);
    try testing.expectEqual(0, open.timestamp_max);

    var too_big: u64 = std.math.maxInt(u64);
    _ = &too_big;
    const nothing = [_]QA{
        (QA{}).where(.ledger, .eq, 1).where(.ledger, .eq, 2),
        (QA{}).where(.ledger, .eq, too_big), // not a u32
        (QA{}).where(.timestamp, .lt, 1), // 0 would mean no bound
        (QA{}).where(.timestamp, .gt, std.math.maxInt(u63)),
        (QA{}).where(.timestamp, .gt, 10).where(.timestamp, .lt, 11),
    };
    for (nothing) |q| try testing.expect(plan(tb.Account, &q).source == .none);
}

test "advance moves the cursor past the last row, and stops at the range's end" {
    var f = std.mem.zeroes(c.tb_query_filter_t);
    try testing.expect(advance(&f, 10));
    try testing.expectEqual(11, f.timestamp_min);
    f.timestamp_max = 20;
    try testing.expect(!advance(&f, 20));

    var r = std.mem.zeroes(c.tb_query_filter_t);
    r.flags = c.TB_QUERY_FILTER_REVERSED;
    r.timestamp_min = 5;
    try testing.expect(advance(&r, 10));
    try testing.expectEqual(9, r.timestamp_max);
    try testing.expect(!advance(&r, 5));
    try testing.expect(!advance(&r, 1));
}

test "window applies offset and limit" {
    try testing.expectEqual(.{ 2, 5 }, window(5, 2, null));
    try testing.expectEqual(.{ 2, 4 }, window(5, 2, 2));
    try testing.expectEqual(.{ 5, 5 }, window(5, 9, 2));
    try testing.expectEqual(.{ 0, 0 }, window(5, 0, 0));
}

test "accountFilter: user_data, code and the timestamp range narrow it; ledger is left to matches" {
    const f = accountFilter(tb.Transfer, &(QT{})
        .where(.code, .eq, 2)
        .where(.user_data_64, .eq, 7)
        .where(.ledger, .eq, 700)
        .where(.timestamp, .between, .{ 10, 20 })
        .order(.timestamp, .desc), 42, c.TB_ACCOUNT_FILTER_DEBITS).?;
    try testing.expectEqual(42, f.account_id);
    try testing.expectEqual(2, f.code);
    try testing.expectEqual(7, f.user_data_64);
    try testing.expectEqual(10, f.timestamp_min);
    try testing.expectEqual(20, f.timestamp_max);
    try testing.expectEqual(@as(u32, c.TB_ACCOUNT_FILTER_DEBITS | c.TB_ACCOUNT_FILTER_REVERSED), f.flags);

    // Balances have only the timestamp to filter on.
    const QB = zom.Query(tb.AccountBalance);
    const b = accountFilter(tb.AccountBalance, &(QB{}).where(.account_id, .eq, 9).where(.timestamp, .gt, 5), 9, c.TB_ACCOUNT_FILTER_CREDITS).?;
    try testing.expectEqual(6, b.timestamp_min);
    try testing.expectEqual(@as(u32, c.TB_ACCOUNT_FILTER_CREDITS), b.flags);

    // A contradiction is null; so is an empty range.
    try testing.expectEqual(null, accountFilter(tb.Transfer, &(QT{}).where(.code, .eq, 1).where(.code, .eq, 2), 1, c.TB_ACCOUNT_FILTER_DEBITS));
    try testing.expectEqual(null, accountFilter(tb.Transfer, &(QT{}).where(.timestamp, .lt, 1), 1, c.TB_ACCOUNT_FILTER_DEBITS));
}

test "advance pages an account filter too, in its direction" {
    var f = std.mem.zeroes(c.tb_account_filter_t);
    f.flags = c.TB_ACCOUNT_FILTER_DEBITS | c.TB_ACCOUNT_FILTER_REVERSED;
    try testing.expect(advance(&f, 50));
    try testing.expectEqual(49, f.timestamp_max);
    try testing.expectEqual(0, f.timestamp_min);
}

test "idsOf: the smallest eq / in filter on a field, or null without one" {
    const QB = zom.Query(tb.AccountBalance);
    try testing.expectEqual(null, idsOf(tb.AccountBalance, &(QB{}).where(.timestamp, .eq, 1), .account_id));
    const ids = idsOf(tb.AccountBalance, &(QB{}).where(.account_id, .in, .{ 4, 5, 4 }), .account_id).?;
    try testing.expectEqualSlices(u128, &.{ 4, 5 }, ids.slice());
}
