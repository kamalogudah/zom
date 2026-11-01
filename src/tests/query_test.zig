const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const like = zom.query.like;

test "like: literals, % and _" {
    try testing.expect(like("Achieng", "Achieng", .sensitive));
    try testing.expect(!like("Achieng", "Achien", .sensitive));
    try testing.expect(!like("Achien", "Achieng", .sensitive));
    try testing.expect(like("Achieng", "Ach%", .sensitive));
    try testing.expect(like("Ach", "Ach%", .sensitive)); // % matches nothing too
    try testing.expect(!like("Otieno", "Ach%", .sensitive));
    try testing.expect(like("Achieng", "%eng", .sensitive));
    try testing.expect(like("Achieng", "%hie%", .sensitive));
    try testing.expect(like("cat", "c_t", .sensitive));
    try testing.expect(!like("ct", "c_t", .sensitive));
    try testing.expect(!like("cart", "c_t", .sensitive));
    try testing.expect(like("cart", "c__t", .sensitive));
    try testing.expect(like("cart", "_%_", .sensitive));
    try testing.expect(!like("c", "_%_", .sensitive));
}

test "like: %a%b% needs backtracking" {
    try testing.expect(like("ab", "%a%b%", .sensitive));
    try testing.expect(like("xxaxxbxx", "%a%b%", .sensitive));
    try testing.expect(like("bab", "%a%b%", .sensitive));
    try testing.expect(!like("ba", "%a%b%", .sensitive));
    try testing.expect(!like("bbb", "%a%b%", .sensitive));
    // The first "ab" is a false start; matching must retry after it.
    try testing.expect(like("abacabd", "%abd", .sensitive));
    try testing.expect(like("aaab", "%a_b", .sensitive));
    try testing.expect(like("mississippi", "%iss%ppi", .sensitive));
    try testing.expect(!like("mississippi", "%iss%ppix", .sensitive));
    try testing.expect(like("abc", "%%%c", .sensitive));
}

test "like: the empty pattern and empty text" {
    try testing.expect(like("", "", .sensitive));
    try testing.expect(!like("a", "", .sensitive));
    try testing.expect(like("", "%", .sensitive));
    try testing.expect(like("", "%%", .sensitive));
    try testing.expect(!like("", "_", .sensitive));
    try testing.expect(!like("", "a", .sensitive));
    try testing.expect(like("anything", "%", .sensitive));
}

test "like: backslash escapes % _ and itself" {
    try testing.expect(like("100%", "100\\%", .sensitive));
    try testing.expect(!like("1000", "100\\%", .sensitive));
    try testing.expect(like("50% off", "%\\%%", .sensitive));
    try testing.expect(!like("50 off", "%\\%%", .sensitive));
    try testing.expect(like("a_b", "a\\_b", .sensitive));
    try testing.expect(!like("axb", "a\\_b", .sensitive));
    try testing.expect(like("a\\b", "a\\\\b", .sensitive));
    try testing.expect(!like("a\\\\b", "a\\\\b", .sensitive));
    try testing.expect(like("ab", "a\\b", .sensitive)); // escaping a plain char is that char
    try testing.expect(like("a\\", "a\\", .sensitive)); // a trailing lone \ is literal
}

test "like: _ is one UTF-8 character, not one byte" {
    try testing.expect(like("café", "caf_", .sensitive));
    try testing.expect(!like("café", "caf__", .sensitive));
    try testing.expect(like("naïve", "na_ve", .sensitive));
    try testing.expect(!like("é", "%__", .sensitive));
    try testing.expect(like("日本語", "___", .sensitive));
    try testing.expect(like("日本語", "_本%", .sensitive));
}

test "ilike folds ASCII case only" {
    try testing.expect(like("Achieng", "ach%", .insensitive));
    try testing.expect(like("ACHIENG", "%hie%", .insensitive));
    try testing.expect(!like("Achieng", "ach%", .sensitive));
    try testing.expect(!like("É", "é", .insensitive));
}

const Role = enum { admin, member, guest };
const Row = struct { id: u32, name: []const u8, age: ?u8, role: Role };
const Q = zom.Query(Row);

const rows = [_]Row{
    .{ .id = 1, .name = "Achieng", .age = 31, .role = .admin },
    .{ .id = 2, .name = "Otieno", .age = 24, .role = .member },
    .{ .id = 3, .name = "Wanjiru", .age = null, .role = .guest },
    .{ .id = 4, .name = "achol", .age = 18, .role = .member },
    .{ .id = 5, .name = "50% Kim", .age = 30, .role = .guest },
};

/// The ids of `rows` that `query` matches, in order.
fn ids(query: Q, buf: *[rows.len]u32) []const u32 {
    var n: usize = 0;
    for (rows) |r| {
        if (query.matches(r)) {
            buf[n] = r.id;
            n += 1;
        }
    }
    return buf[0..n];
}

fn expectIds(query: Q, want: []const u32) !void {
    var buf: [rows.len]u32 = undefined;
    try testing.expectEqualSlices(u32, want, ids(query, &buf));
}

test "in / not_in with a comptime tuple" {
    const q: Q = .{};
    try expectIds(q.where(.id, .in, .{ 1, 3, 9 }), &.{ 1, 3 });
    try expectIds(q.where(.id, .not_in, .{ 1, 3, 9 }), &.{ 2, 4, 5 });
    try expectIds(q.where(.name, .in, .{ "Otieno", "achol" }), &.{ 2, 4 });
    try expectIds(q.where(.role, .in, .{ .admin, .guest }), &.{ 1, 3, 5 });
    try expectIds(q.where(.role, .not_in, .{.member}), &.{ 1, 3, 5 });
    try expectIds(q.where(.id, .in, .{}), &.{});
    try expectIds(q.where(.id, .not_in, .{}), &.{ 1, 2, 3, 4, 5 });
}

test "in / not_in follow SQL null semantics" {
    const q: Q = .{};
    // NULL IN (...) never matches, NULL NOT IN (...) neither.
    try expectIds(q.where(.age, .in, .{ 24, 31 }), &.{ 1, 2 });
    try expectIds(q.where(.age, .not_in, .{ 24, 31 }), &.{ 4, 5 });
    // A null in the list never equals anything...
    try expectIds(q.where(.age, .in, .{ 24, null }), &.{2});
    // ...and makes NOT IN unknown for every row.
    try expectIds(q.where(.age, .not_in, .{ 24, null }), &.{});
    try expectIds(q.where(.age, .not_in, .{}), &.{ 1, 2, 4, 5 });
}

test "whereIn borrows a runtime slice of any attribute type" {
    const q: Q = .{};
    var keys = [_]u32{ 4, 2 };
    const by_ids = q.whereIn(.id, &keys);
    try expectIds(by_ids, &.{ 2, 4 });
    const slice: []const u32 = &keys;
    try expectIds(q.whereNotIn(.id, slice), &.{ 1, 3, 5 });

    // The query reads the caller's memory at match time; nothing was copied.
    keys[0] = 5;
    try expectIds(by_ids, &.{ 2, 5 });

    const roles = [_]Role{.member};
    try expectIds(q.whereIn(.role, &roles), &.{ 2, 4 });
    const ages = [_]?u8{ 18, null };
    try expectIds(q.whereIn(.age, &ages), &.{4});
    try expectIds(q.whereIn(.id, @as([]const u32, &.{})), &.{});
}

test "a tuple's values are static, so the query outlives the call that built it" {
    const build = struct {
        fn build() Q {
            const q: Q = .{};
            return q.where(.name, .in, .{ "Otieno", "Wanjiru" });
        }
    }.build;
    const q = build();
    // Clobber the stack the builder used.
    var junk: [4096]u8 = undefined;
    @memset(&junk, 0xaa);
    std.mem.doNotOptimizeAway(&junk);
    try expectIds(q, &.{ 2, 3 });
}

test "building a full query with in, between and like takes no allocator" {
    // Nothing here can allocate: there is no allocator in scope. The query
    // is a plain value holding at most max_filters filters.
    var q: Q = .{};
    q = q.where(.id, .in, .{ 1, 2, 3, 4, 5 }).where(.age, .between, .{ 18, 31 }).where(.name, .ilike, "%o%");
    try testing.expectEqual(@as(usize, 3), q.filter_count);
    try expectIds(q, &.{ 2, 4 });
    // `in` lists are borrowed, not stored per filter: a query stays about
    // 1 KiB, where `[max_in]Value` in every filter would make it ~24 KiB.
    try testing.expect(@sizeOf(Q) < 2 * 1024);
}

test "between is inclusive and never matches null" {
    const q: Q = .{};
    try expectIds(q.where(.age, .between, .{ 24, 31 }), &.{ 1, 2, 5 });
    try expectIds(q.where(.age, .between, .{ 24, 24 }), &.{2});
    try expectIds(q.where(.age, .between, .{ 31, 24 }), &.{}); // lo > hi: empty, as in SQL
    try expectIds(q.where(.age, .between, .{ null, 31 }), &.{});
    try expectIds(q.where(.name, .between, .{ "A", "Z" }), &.{ 1, 2, 3 });
    // Enums compare in declaration order.
    try expectIds(q.where(.role, .between, .{ .member, .guest }), &.{ 2, 3, 4, 5 });
    var lo: u32 = 2;
    _ = &lo;
    try expectIds(q.where(.id, .between, .{ lo, 3 }), &.{ 2, 3 });
}

test "like / ilike on a relation attribute" {
    const q: Q = .{};
    try expectIds(q.where(.name, .like, "Ach%"), &.{1});
    try expectIds(q.where(.name, .ilike, "Ach%"), &.{ 1, 4 });
    try expectIds(q.where(.name, .like, "%i%"), &.{ 1, 2, 3, 5 });
    try expectIds(q.where(.name, .like, "50\\%%"), &.{5});
    try expectIds(q.where(.name, .like, ""), &.{});
    var pattern: []const u8 = "_tieno";
    _ = &pattern;
    try expectIds(q.where(.name, .like, pattern), &.{2});
}

test "is_null / is_not_null, and eq null as their alias" {
    const q: Q = .{};
    try expectIds(q.where(.age, .is_null, {}), &.{3});
    try expectIds(q.where(.age, .is_not_null, {}), &.{ 1, 2, 4, 5 });

    const eq_null = q.where(.age, .eq, null);
    try expectIds(eq_null, &.{3});
    try testing.expectEqual(zom.Op.is_null, eq_null.filterSlice()[0].op);
    const neq_null = q.where(.age, .neq, null);
    try expectIds(neq_null, &.{ 1, 2, 4, 5 });
    try testing.expectEqual(zom.Op.is_not_null, neq_null.filterSlice()[0].op);
    // A hand-built eq-null filter gets the same treatment.
    var raw: Q = .{};
    raw.addFilter(.{ .field = .age, .op = .eq, .operand = .{ .one = .null } });
    try testing.expectEqual(zom.Op.is_null, raw.filterSlice()[0].op);

    try expectIds(q.where(.age, .lt, null), &.{});
}

test "every op has an operand shape and a SQL spelling" {
    inline for (@typeInfo(zom.Op).@"enum".fields) |f| {
        const op: zom.Op = @enumFromInt(f.value);
        try testing.expect(op.sql().len > 0);
        _ = op.operand();
    }
}
