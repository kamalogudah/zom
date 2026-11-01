//! One piece of relation code, run unchanged on the memory gateway and on
//! zom-pg. `scenario` is written once, generic over the gateway type, and
//! each test only says how to open a gateway. The memory run always
//! happens; the Postgres run is skipped unless `ZOM_PG_URL` is set (see
//! lint_test.zig) and drops and recreates the `sc_books` table.
//!
//! Lint checks each operation on its own; this checks that a realistic
//! sequence of them, written like application code (free with `free` /
//! `freeOne`, create with `commitAlloc`), gives the same answers on both.

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Genre = enum { fiction, essay, poetry };

const Book = struct {
    id: u32,
    title: []const u8,
    genre: Genre,
    pages: u16,
    rating: ?u8,
};

const Books = zom.Schema(Book, "sc_books", .id);

const create_table =
    \\CREATE TABLE sc_books (
    \\  id bigint PRIMARY KEY,
    \\  title text NOT NULL,
    \\  genre text NOT NULL,
    \\  pages integer NOT NULL,
    \\  rating smallint
    \\)
;

const seed = [_]Book{
    .{ .id = 1, .title = "Kintu", .genre = .fiction, .pages = 445, .rating = 5 },
    .{ .id = 2, .title = "Decolonising the Mind", .genre = .essay, .pages = 114, .rating = 4 },
    .{ .id = 3, .title = "Song of Lawino", .genre = .poetry, .pages = 216, .rating = null },
    .{ .id = 4, .title = "Petals of Blood", .genre = .fiction, .pages = 345, .rating = 4 },
};

fn scenario(comptime G: type, gw: *G) !void {
    const a = testing.allocator;
    const books = try zom.Relation(Books, G).init(gw);

    // Create: a batch, then one more, then a clash on the key.
    try testing.expectEqual(seed.len, try books.createMany(&seed).commit());
    const stored = try books.create(.{ .id = 5, .title = "Dust", .genre = .fiction, .pages = 368, .rating = null }).commitAlloc(a);
    try testing.expectEqualStrings("Dust", stored.title);
    books.freeOne(a, stored);
    try testing.expectError(error.DuplicatePrimaryKey, books.create(seed[0]).commitAlloc(a));
    try testing.expectEqual(5, try books.count());

    // Filters, ordering and paging.
    {
        const fiction = try books.where(.genre, .eq, .fiction).order(.pages, .desc).toSlice(a);
        defer books.free(a, fiction);
        try expectIds(&.{ 1, 5, 4 }, fiction);
    }
    {
        const page = try books.order(.title, .asc).offset(1).limit(2).toSlice(a);
        defer books.free(a, page);
        try expectIds(&.{ 5, 1 }, page);
    }
    {
        const unrated = try books.where(.rating, .eq, null).order(.id, .asc).toSlice(a);
        defer books.free(a, unrated);
        try expectIds(&.{ 3, 5 }, unrated);
    }
    {
        const either = try books.whereAny(.{ .{ .genre, .eq, .poetry }, .{ .pages, .lt, 200 } }).order(.id, .asc).toSlice(a);
        defer books.free(a, either);
        try expectIds(&.{ 2, 3 }, either);
    }
    {
        const picked = try books.whereIn(.id, &[_]u32{ 4, 2, 99 }).order(.id, .asc).toSlice(a);
        defer books.free(a, picked);
        try expectIds(&.{ 2, 4 }, picked);
    }
    try testing.expectEqual(3, try books.where(.rating, .gte, 4).count());

    // A projection reads only the selected fields.
    {
        const rel = books.where(.pages, .gt, 300).order(.id, .asc).select(.{ .id, .title });
        const titles = try rel.toSlice(a);
        defer rel.free(a, titles);
        try testing.expectEqual(2, @typeInfo(@TypeOf(titles[0])).@"struct".fields.len);
        try testing.expectEqual(3, titles.len);
        try testing.expectEqualStrings("Kintu", titles[0].title);
        try testing.expectEqualStrings("Petals of Blood", titles[1].title);
        try testing.expectEqualStrings("Dust", titles[2].title);
    }

    // Updates: by key, by filter, and one that doesn't fit the field.
    try testing.expectEqual(1, try books.byPk(3).update().set(.rating, 3).commit());
    // #2 is also rated 4, but it is an essay: the filters are ANDed.
    try testing.expectEqual(1, try books.where(.genre, .eq, .fiction).where(.rating, .eq, 4).update().set(.rating, 5).commit());
    // A literal 300 is a compile error; a runtime value is checked on commit.
    var too_big: i64 = 300;
    _ = &too_big;
    try testing.expectError(error.ValueOutOfRange, books.byPk(1).update().set(.rating, too_big).commit());
    if (try books.byPk(3).one(a)) |b| {
        defer books.freeOne(a, b);
        try testing.expectEqual(3, b.rating);
    } else return error.TestExpectedRow;

    // Deletes.
    try testing.expectEqual(1, try books.where(.genre, .eq, .essay).delete());
    try testing.expectEqual(null, try books.byPk(2).one(a));
    try testing.expectEqual(2, try books.where(.rating, .eq, 5).count());
    try testing.expectEqual(4, try books.delete());
    try testing.expectEqual(0, try books.count());
}

fn expectIds(expected: []const u32, rows: []const Book) !void {
    var ids: [8]u32 = undefined;
    try testing.expectEqual(expected.len, rows.len);
    for (rows, 0..) |r, i| ids[i] = r.id;
    try testing.expectEqualSlices(u32, expected, ids[0..rows.len]);
}

test "scenario: memory" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    try scenario(zom.memory.Gateway, &gw);
}

test "scenario: postgres" {
    const u = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(u);
    var gw = try zom_pg.Gateway.init(testing.allocator, .{ .io = testing.io, .url = u, .pool_size = 2 });
    defer gw.deinit();
    try gw.exec("DROP TABLE IF EXISTS sc_books");
    defer gw.exec("DROP TABLE IF EXISTS sc_books") catch {};
    try gw.exec(create_table);
    try scenario(zom_pg.Gateway, &gw);
}
