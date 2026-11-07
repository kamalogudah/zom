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
    // `in` lists are borrowed, not stored per filter: a query stays a few
    // KiB (about 1 KiB of filters plus `max_joins` joins of ~760 bytes
    // each), where `[max_in]Value` in every filter would make it ~24 KiB.
    try testing.expect(@sizeOf(Q) < 4 * 1024);
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

test "every op has an operand shape" {
    inline for (@typeInfo(zom.Op).@"enum".field_values) |value| {
        const op: zom.Op = @fromBackingInt(value);
        _ = op.operand();
    }
}

test "whereAny ORs its conditions, and ANDs the group with the rest" {
    const q: Q = .{};
    // age > 30 OR role = guest: Achieng (31), Wanjiru and 50% Kim (guests).
    const any = q.whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .guest } });
    try expectIds(any, &.{ 1, 3, 5 });
    try expectIds(any.where(.age, .is_not_null, {}), &.{ 1, 5 });
    try expectIds(q.where(.id, .gt, 1).whereAny(.{ .{ .name, .like, "A%" }, .{ .id, .eq, 4 } }), &.{4});

    // Nesting: (role = admin) OR (role = member AND age < 20).
    try expectIds(q.whereAny(.{
        .{ .role, .eq, .admin },
        zom.all(.{ .{ .role, .eq, .member }, .{ .age, .lt, 20 } }),
    }), &.{ 1, 4 });

    // A runtime value, and a runtime slice for `in`, work inside a group.
    var min: u8 = 30;
    _ = &min;
    const keys = [_]u32{ 2, 4 };
    try expectIds(q.whereAny(.{ .{ .age, .gt, min }, .{ .id, .in, @as([]const u32, &keys) } }), &.{ 1, 2, 4 });
    try expectIds(q.whereAny(.{ .{ .age, .gte, min }, .{ .id, .in, .{3} } }), &.{ 1, 3, 5 });
}

test "NOT follows SQL's three-valued logic: NOT (NULL > 30) is not true" {
    const q: Q = .{};
    // Wanjiru's age is null: age > 30 is unknown for her, and so is its
    // negation, so she matches neither.
    try expectIds(q.where(.age, .gt, 30), &.{1});
    try expectIds(q.whereNot(.{ .age, .gt, 30 }), &.{ 2, 4, 5 });
    const wanjiru = rows[2];
    try testing.expectEqual(@as(?bool, null), q.whereNot(.{ .age, .gt, 30 }).truth(wanjiru));
    // NOT of something that is never unknown is plain negation.
    try expectIds(q.whereNot(.{ .age, .is_null, {} }), &.{ 1, 2, 4, 5 });
    // Double negation gives the original back, unknowns still excluded.
    try expectIds(q.whereNot(zom.not(.{ .age, .gt, 30 })), &.{1});

    // Unknown OR true is true; unknown OR false stays unknown.
    try expectIds(q.whereNot(zom.any(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .guest } })), &.{ 2, 4 });
    try expectIds(q.whereNot(zom.any(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })), &.{ 2, 4, 5 });
    // Unknown AND false is false, so its negation is true.
    try expectIds(q.whereNot(zom.all(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })), &.{ 2, 3, 4, 5 });
}

test "NOT of in, not_in and between with nulls in the operand" {
    const q: Q = .{};
    // age IN (24, NULL): true for 24, unknown for every other age.
    try expectIds(q.whereNot(.{ .age, .in, .{ 24, null } }), &.{});
    // age NOT IN (24, NULL): false for 24, unknown otherwise. Its NOT is
    // true for 24 only.
    try expectIds(q.whereNot(.{ .age, .not_in, .{ 24, null } }), &.{2});
    // age BETWEEN NULL AND 25 = age >= NULL AND age <= 25: false above 25,
    // unknown at or below, so its NOT is true above 25 only.
    try expectIds(q.whereNot(.{ .age, .between, .{ null, 25 } }), &.{ 1, 5 });
    try expectIds(q.whereNot(.{ .id, .in, .{} }), &.{ 1, 2, 3, 4, 5 });
}

test "three-valued AND / OR / NOT tables" {
    const and3 = zom.query.and3;
    const or3 = zom.query.or3;
    const not3 = zom.query.not3;
    const values = [_]?bool{ true, false, null };
    // Rows: a; columns: b. In SQL order TRUE, FALSE, UNKNOWN.
    const and_table = [3][3]?bool{ .{ true, false, null }, .{ false, false, false }, .{ null, false, null } };
    const or_table = [3][3]?bool{ .{ true, true, true }, .{ true, false, null }, .{ true, null, null } };
    for (values, 0..) |a, i| for (values, 0..) |b, j| {
        try testing.expectEqual(and_table[i][j], and3(a, b));
        try testing.expectEqual(or_table[i][j], or3(a, b));
    };
    try testing.expectEqual(@as(?bool, false), not3(true));
    try testing.expectEqual(@as(?bool, true), not3(false));
    try testing.expectEqual(@as(?bool, null), not3(null));
}

test "the filter tree is flat: groups index their children, filters stay in filters" {
    const q: Q = .{};
    const tree = q.where(.id, .gt, 0).whereNot(zom.any(.{ .{ .age, .gt, 30 }, zom.all(.{ .{ .role, .eq, .guest }, .{ .id, .eq, 3 } }) }));
    try testing.expect(!tree.isConjunction());
    try testing.expectEqual(@as(usize, 4), tree.filter_count);
    // 0: id > 0, 1: NOT 2, 2: OR 3..4, 3: age > 30, 4: AND 5..6, 5, 6: filters.
    try testing.expectEqual(@as(u8, 7), tree.node_count);
    const nodes = tree.nodeSlice();
    try testing.expectEqual(@as(u8, 2), nodes[1].not);
    try testing.expectEqual(Q.Children{ .first = 3, .len = 2 }, nodes[2].or_group);
    try testing.expectEqual(Q.Children{ .first = 5, .len = 2 }, nodes[4].and_group);
    var top = tree.topNodes();
    try testing.expectEqual(@as(?usize, 0), top.next());
    try testing.expectEqual(@as(?usize, 1), top.next());
    try testing.expectEqual(@as(?usize, null), top.next());
    // id > 0 AND NOT (age > 30 OR (guest AND id = 3)): Wanjiru (3) is out
    // by the AND; Achieng by age; 50% Kim is a guest but not id 3.
    try expectIds(tree, &.{ 2, 4, 5 });

    // A query with only `where` stays a conjunction, for filterSlice.
    const flat = q.where(.id, .gt, 0).where(.age, .lt, 30);
    try testing.expect(flat.isConjunction());
    try testing.expectEqual(@as(usize, 2), flat.filterSlice().len);
}

test "copying a query copies the tree" {
    const q: Q = .{};
    const a = q.whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .guest } });
    var b = a;
    // Rewrite the copy's OR group in place: a points at none of it.
    const children = b.nodes[0].or_group;
    b.nodes[0] = .{ .and_group = children };
    b.filters[0].operand = .{ .one = .{ .int = 0 } };
    // age > 0 AND role = guest: Wanjiru's null age is out.
    try expectIds(b, &.{5});
    try expectIds(a, &.{ 1, 3, 5 });
    // Chaining from the copy leaves the original alone too.
    try expectIds(a.where(.id, .neq, 1), &.{ 3, 5 });
    try expectIds(a, &.{ 1, 3, 5 });
}

test "a query fills up to max_filters through groups" {
    var q: Q = .{};
    for (0..Q.max_filters / 2) |_| q = q.whereAny(.{ .{ .id, .eq, 1 }, .{ .id, .eq, 2 } });
    try testing.expectEqual(@as(usize, Q.max_filters), q.filter_count);
    try testing.expectEqual(@as(u8, Q.max_filters / 2 * 3), q.node_count);
    try expectIds(q, &.{ 1, 2 });
}

test "addNodeFrom splits a query into two that AND back to it" {
    const q = (Q{})
        .where(.age, .gt, 20)
        .whereAny(.{ .{ .role, .eq, .admin }, zom.all(.{ .{ .id, .gte, 4 }, zom.not(.{ .name, .like, "%z%" }) }) })
        .whereNot(.{ .id, .eq, 5 })
        .where(.name, .neq, "Otieno");

    // Groups to one side, plain filters to the other.
    var groups: Q = .{};
    var plain: Q = .{};
    var it = q.topNodes();
    while (it.next()) |i| {
        const index: u8 = @intCast(i);
        if (q.nodes[index] == .filter) plain.addNodeFrom(&q, index) else groups.addNodeFrom(&q, index);
    }
    try testing.expect(plain.isConjunction());
    try testing.expectEqual(2, plain.filter_count);
    try testing.expectEqual(q.node_count, groups.node_count + plain.node_count);
    try testing.expectEqual(q.filter_count, groups.filter_count + plain.filter_count);

    for (rows) |row| {
        try testing.expectEqual(q.truth(row), zom.query.and3(groups.truth(row), plain.truth(row)));
    }

    // Copying every top node into an empty query gives the same query.
    var whole: Q = .{};
    it = q.topNodes();
    while (it.next()) |i| whole.addNodeFrom(&q, @intCast(i));
    for (rows) |row| try testing.expectEqual(q.truth(row), whole.truth(row));
    try testing.expectEqual(q.node_count, whole.node_count);
}
