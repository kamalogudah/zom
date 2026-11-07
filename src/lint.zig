//! zom.lint = rom's `ROM::Lint`: the conformance suite every adapter runs.
//!
//! It is a library of tests, not a test file. An adapter calls it from its
//! own `zig build test`:
//!
//!     test "zom.lint" {
//!         try zom.lint.run(zom_csv.Gateway, Factory);
//!     }
//!
//! Lint defines its own schema (`Users`) and seed rows, so every adapter is
//! tested on the same data. Each check gets a fresh gateway from the factory,
//! seeded with `users`, and goes through `zom.Relation` like application code.
//! An adapter with `supports.join` is also given the join check, which seeds
//! and joins two more schemas, `Posts` and `Comments` (datasets `lint_posts`
//! and `lint_comments`), so its factory must provide those too, empty, as it
//! does `lint_users`.
//!
//! The factory says how to make a gateway, because each adapter needs a
//! different setup (memory needs nothing, CSV a temporary directory, Postgres
//! a URL and a clean table):
//!
//!     const Factory = struct {
//!         pub fn create(allocator: std.mem.Allocator) !G { ... }
//!         pub fn destroy(g: *G) void { ... }
//!         // Required when the dataset has neither `insert` nor `insertMany`;
//!         // otherwise lint seeds through those.
//!         pub fn seed(g: *G, comptime S: type, rows: []const S.Tuple) !void { ... }
//!         // Optional: what a failed `insertMany` leaves stored (see
//!         // `OnDuplicate`). Defaults to `.stores_nothing` with `insertMany`
//!         // and `.stores_prefix` for the `insert` loop fallback.
//!         pub const insert_many_on_duplicate: zom.lint.OnDuplicate = .stores_nothing;
//!     };
//!
//! `create` must not keep a pointer to the returned gateway: lint stores it
//! on the stack and only then calls `dataset` on it.
//!
//! Every check runs, even after one fails. A failing check prints its name
//! (and the case, for table-driven checks) to stderr, and `run` returns the
//! first error. A check that needs a capability or query feature the adapter
//! lacks is skipped with a line saying why. Everything allocates through
//! `std.testing.allocator`, so the test that calls `run` also fails on leaks.
//!
//! Lint frees what it reads the portable way, with the relation's `free`
//! and `freeOne`, and creates through `commitAlloc`, so a dataset with
//! caller-owned strings (`strings = .caller`) is checked for leaks too: every
//! string it returns must be allocated with the allocator it was given.

const std = @import("std");
const testing = std.testing;
const adapter = @import("adapter.zig");
const Schema = @import("schema.zig").Schema;
const hasMany = @import("schema.zig").hasMany;
const belongsTo = @import("schema.zig").belongsTo;
const RelationOf = @import("relation.zig").Relation;
const query = @import("query.zig");
const strings = @import("strings.zig");

pub const Role = enum { a, b, c };

pub const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    role: Role,
};

pub const Users = Schema(User, "lint_users", .id, .{
    .associations = struct {
        pub const posts = hasMany(Posts, .user_id);
        pub const comments = hasMany(Comments, .user_id);
    },
});

/// The other side of the join check, the only check that uses it.
pub const Post = struct {
    id: u32,
    user_id: ?u32,
    title: []const u8,
    published: bool,
};

pub const Posts = Schema(Post, "lint_posts", .id, .{
    .associations = struct {
        pub const author = belongsTo(Users, .user_id);
    },
});

/// Seeded by the join check only. bob has two posts, so a join that does
/// not remove duplicates returns him twice; dee, eve and fay have none, and
/// post 24 belongs to nobody.
pub const posts = [_]Post{
    .{ .id = 20, .user_id = 4, .title = "b1", .published = true },
    .{ .id = 21, .user_id = 4, .title = "b2", .published = true },
    .{ .id = 22, .user_id = 2, .title = "a1", .published = false },
    .{ .id = 23, .user_id = 6, .title = "c1", .published = true },
    .{ .id = 24, .user_id = null, .title = "orphan", .published = true },
};

/// The third side of the join check, joined with `Posts` in the same query.
pub const Comment = struct {
    id: u32,
    user_id: ?u32,
    body: []const u8,
    flagged: bool,
};

pub const Comments = Schema(Comment, "lint_comments", .id, .{});

/// Seeded by the join check only. bob comments twice; dee, who has no
/// post, once; ada once, flagged. Comment 33 belongs to nobody. So bob and
/// ada have a post and a comment, cy a post only and dee a comment only.
pub const comments = [_]Comment{
    .{ .id = 30, .user_id = 4, .body = "b", .flagged = false },
    .{ .id = 31, .user_id = 4, .body = "b again", .flagged = false },
    .{ .id = 32, .user_id = 1, .body = "d", .flagged = false },
    .{ .id = 34, .user_id = 2, .body = "a", .flagged = true },
    .{ .id = 33, .user_id = null, .body = "orphan", .flagged = true },
};

/// The seed rows. They are stored out of key order, and the names do not
/// sort the same way as the ids, so ordering by the wrong attribute (or not
/// sorting at all) gives a different result.
pub const users = [_]User{
    .{ .id = 4, .name = "bob", .age = 52, .role = .a },
    .{ .id = 1, .name = "dee", .age = 36, .role = .a },
    .{ .id = 6, .name = "cy", .age = 25, .role = .c },
    .{ .id = 2, .name = "ada", .age = null, .role = .b },
    .{ .id = 5, .name = "eve", .age = null, .role = .b },
    .{ .id = 3, .name = "fay", .age = 17, .role = .c },
};

/// What `createMany` leaves stored when one tuple in the batch has a
/// primary key already in use. A factory declares it as
/// `pub const insert_many_on_duplicate`.
pub const OnDuplicate = enum {
    /// All or nothing: no tuple of the batch is stored.
    stores_nothing,
    /// The tuples before the failing one are stored, as with the fallback
    /// loop over `insert`.
    stores_prefix,
};

/// A named check, with what the adapter must have for it to run.
const Check = struct {
    name: []const u8,
    /// Dataset capabilities the check uses.
    needs: []const adapter.Capability = &.{},
    /// Dataset capabilities of which the check needs at least one.
    needs_any: []const adapter.Capability = &.{},
    /// `zom.Supports` fields that must be true for the check to run.
    features: []const []const u8 = &.{},
    /// Attributes of `Users` the check orders by: it is skipped when the
    /// dataset can't order by one of them (`supports.order_on`, or its
    /// `orderable`).
    orders: []const []const u8 = &.{},
};

const checks = .{
    .{ Check{ .name = "read: no filters returns every row" }, checkReadAll },
    .{ Check{ .name = "read: strings stay valid after later reads", .orders = &.{"id"} }, checkReadStrings },
    .{ Check{ .name = "filter: every op on an int attribute" }, checkIntOps },
    .{ Check{ .name = "filter: eq/neq on string and enum attributes" }, checkStringOps },
    .{ Check{ .name = "filter: null semantics" }, checkNulls },
    .{ Check{ .name = "filter: in / not_in, from a tuple and from a slice", .features = &.{"in"}, .orders = &.{"id"} }, checkIn },
    .{ Check{ .name = "filter: like / ilike", .features = &.{"like"} }, checkLike },
    .{ Check{ .name = "filter: between, inclusive" }, checkBetween },
    .{ Check{ .name = "filter: or / not groups, with SQL's three-valued logic", .features = &.{"or"}, .orders = &.{"id"} }, checkBoolean },
    .{ Check{ .name = "order: on the primary key", .orders = &.{"id"} }, checkOrderPk },
    .{ Check{ .name = "order: on other attributes and on several, nulls last on asc", .features = &.{"order_on"}, .orders = &.{ "name", "age", "role", "id" } }, checkOrderOn },
    .{ Check{ .name = "limit", .orders = &.{"id"} }, checkLimit },
    .{ Check{ .name = "offset", .features = &.{"offset"}, .orders = &.{"id"} }, checkOffset },
    .{ Check{ .name = "one: null, one tuple, or error.MoreThanOneTuple", .orders = &.{"id"} }, checkOne },
    .{ Check{ .name = "select: readProjected keeps filters, order and limit", .features = &.{ "projection", "order_on" }, .orders = &.{ "age", "id", "name" } }, checkProjection },
    .{ Check{ .name = "join: rows with a matching row in another dataset, each once", .features = &.{"join"}, .orders = &.{"id"} }, checkJoin },
    .{ Check{ .name = "per_group_limit: limit and offset page each group, as Query.pageGroups does", .features = &.{"per_group_limit"}, .orders = &.{ "id", "name" } }, checkPerGroup },
    .{ Check{ .name = "insert: returns the stored tuple, error.DuplicatePrimaryKey", .needs = &.{.writable} }, checkInsert },
    .{ Check{ .name = "insert: strings are copied", .needs = &.{.writable} }, checkInsertCopies },
    .{ Check{ .name = "insertMany: count, error.DuplicatePrimaryKey", .needs_any = &.{ .batch_insert, .writable } }, checkInsertMany },
    .{ Check{ .name = "update: count, error.DuplicatePrimaryKey, error.ValueOutOfRange", .needs = &.{.updatable} }, checkUpdate },
    .{ Check{ .name = "delete: count, rows gone", .needs = &.{.deletable} }, checkDelete },
};

/// Runs every check against gateway `G`, built by factory `F`.
pub fn run(comptime G: type, comptime F: type) !void {
    comptime checkFactory(G, F);
    const A = adapter.Adapter(G);

    var first: ?anyerror = null;
    var failed: usize = 0;
    inline for (checks) |entry| {
        const c: Check = entry[0];
        if (comptime skipReason(A, c)) |why| {
            std.debug.print("zom.lint [{s}]: skipped: {s} ({s})\n", .{ A.name, c.name, why });
        } else {
            entry[1](G, F) catch |err| {
                std.debug.print("zom.lint [{s}]: FAILED: {s}: {t}\n", .{ A.name, c.name, err });
                failed += 1;
                if (first == null) first = err;
            };
        }
    }
    if (first) |err| {
        std.debug.print("zom.lint [{s}]: {d} of {d} checks failed\n", .{ A.name, failed, checks.len });
        return err;
    }
}

/// A check that can't run on an adapter, and why.
pub const Skip = struct {
    check: []const u8,
    reason: []const u8,
};

/// The checks that `S`'s dataset in `G` lacks a capability for (`update`
/// and `delete` on a dataset without `updatable` / `deletable`, ...), with
/// the reason `run` would print. For an adapter whose fixed schemas can't
/// hold lint's `Users` (TigerBeetle), so `run` can't be called: it runs its
/// own read checks and reports these, so its log says which of lint's write
/// checks don't apply, as `run`'s does. Query-feature skips (`like`, an
/// order) depend on `Users`, so they are not included.
pub fn capabilitySkips(comptime G: type, comptime S: type) []const Skip {
    const skips = comptime blk: {
        const A = adapter.Adapter(G);
        var out: []const Skip = &.{};
        for (checks) |entry| {
            const c: Check = entry[0];
            if (capabilityGap(A, S, c)) |why| out = out ++ [_]Skip{.{ .check = c.name, .reason = why }};
        }
        break :blk out;
    };
    return skips;
}

/// Prints `capabilitySkips(G, S)` as `run` prints a skipped check, naming
/// the dataset, and returns them.
pub fn printSkips(comptime G: type, comptime S: type) []const Skip {
    const skips = comptime capabilitySkips(G, S);
    inline for (skips) |s| std.debug.print("zom.lint [{s}]: skipped on '{s}': {s} ({s})\n", .{ adapter.Adapter(G).name, S.name, s.check, s.reason });
    return skips;
}

/// Why `S`'s dataset can't run check `c`, as far as capabilities go.
fn capabilityGap(comptime A: type, comptime S: type, comptime c: Check) ?[]const u8 {
    // Checking the dataset contract for every entry in `checks` adds up.
    @setEvalBranchQuota(10_000);
    for (c.needs) |cap| {
        if (!A.has(S, cap))
            return std.fmt.comptimePrint("dataset has no `{t}` capability", .{cap});
    }
    if (c.needs_any.len > 0) {
        for (c.needs_any) |cap| {
            if (A.has(S, cap)) break;
        } else {
            var tags: []const u8 = "";
            for (c.needs_any, 0..) |cap, i| tags = tags ++ (if (i == 0) "" else " or ") ++ "`" ++ @tagName(cap) ++ "`";
            return "dataset has no " ++ tags ++ " capability";
        }
    }
    return null;
}

fn skipReason(comptime A: type, comptime c: Check) ?[]const u8 {
    @setEvalBranchQuota(10_000);
    if (capabilityGap(A, Users, c)) |why| return why;
    const s = A.supports(Users);
    for (c.features) |f| {
        if (!@field(s, f))
            return std.fmt.comptimePrint("dataset does not support `{s}`", .{f});
    }
    for (c.orders) |f| {
        if (A.orderGap(Users, f)) |why|
            return std.fmt.comptimePrint("it orders by '{s}', but {s}", .{ f, why });
    }
    return null;
}

fn checkFactory(comptime G: type, comptime F: type) void {
    const A = adapter.Adapter(G);
    var problems: []const u8 = "";
    if (!@hasDecl(F, "create"))
        problems = problems ++ "\n  - missing `pub fn create(std.mem.Allocator) !Gateway`";
    if (!@hasDecl(F, "destroy"))
        problems = problems ++ "\n  - missing `pub fn destroy(*Gateway) void`";
    if (!@hasDecl(F, "seed") and !A.has(Users, .writable) and !A.has(Users, .batch_insert))
        problems = problems ++ "\n  - missing `pub fn seed(*Gateway, comptime S: type, []const S.Tuple) !void`" ++
            " (the dataset has no `insert` or `insertMany` to seed through)";
    if (@hasDecl(F, "insert_many_on_duplicate") and @TypeOf(F.insert_many_on_duplicate) != OnDuplicate)
        problems = problems ++ "\n  - `insert_many_on_duplicate` must be a `zom.lint.OnDuplicate`, found `" ++
            @typeName(@TypeOf(F.insert_many_on_duplicate)) ++ "`";
    if (problems.len > 0)
        @compileError("zom.lint: factory '" ++ @typeName(F) ++ "' for adapter '" ++ A.name ++ "' is incomplete:" ++ problems);
}

// -- fixture ---------------------------------------------------------------

/// A fresh, seeded gateway. Lives on the caller's stack; call `deinit`.
fn Fixture(comptime G: type, comptime F: type) type {
    return struct {
        const Self = @This();
        pub const Relation = RelationOf(Users, G);

        gateway: G,

        fn init(self: *Self) !Relation {
            self.gateway = try F.create(testing.allocator);
            errdefer F.destroy(&self.gateway);
            try seed(&self.gateway, Users, &users);
            return Relation.init(&self.gateway);
        }

        fn deinit(self: *Self) void {
            F.destroy(&self.gateway);
        }

        fn seed(g: *G, comptime S: type, rows: []const S.Tuple) !void {
            if (@hasDecl(F, "seed")) return F.seed(g, S, rows);
            const A = adapter.Adapter(G);
            const d = try g.dataset(S);
            if (comptime A.has(S, .batch_insert)) {
                try testing.expectEqual(rows.len, try d.insertMany(rows));
            } else if (comptime A.insertTakesAllocator(S)) {
                for (rows) |row| {
                    const stored = try d.insert(row, testing.allocator);
                    if (comptime A.stringOwnership(S) == .caller)
                        strings.freeFields(S.Tuple, testing.allocator, stored, &.{});
                }
            } else {
                for (rows) |row| _ = try d.insert(row);
            }
        }
    };
}

// -- helpers ---------------------------------------------------------------

const Order = enum { any, as_read };

/// Reads `rel` and checks its ids against `want` (sorted when `order` is
/// `.any`), and that `count` agrees with the number of rows read.
fn expectIds(rel: anytype, label: []const u8, order: Order, want: []const u32) !void {
    errdefer std.debug.print("zom.lint:   case: {s}\n", .{label});
    const rows = try rel.toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);

    var buf: [users.len]u32 = undefined;
    if (rows.len > buf.len) {
        std.debug.print("zom.lint:   read returned {d} rows, only {d} are seeded\n", .{ rows.len, users.len });
        return error.TestUnexpectedResult;
    }
    const ids = buf[0..rows.len];
    for (rows, ids) |row, *id| id.* = row.id;
    if (order == .any) std.mem.sort(u32, ids, {}, std.sort.asc(u32));

    try testing.expectEqualSlices(u32, want, ids);
    try expectCount(rel, rows.len);
}

fn expectCount(rel: anytype, want: usize) !void {
    const n = try rel.count();
    if (n != want) {
        std.debug.print("zom.lint:   count returned {d}, read returned {d} rows\n", .{ n, want });
        return error.TestExpectedEqual;
    }
}

/// Like `expectIds` for ordering on `age`, where tied rows may come back in
/// any order, so the ages are compared instead of the ids.
fn expectAges(rel: anytype, label: []const u8, want: []const ?u8) !void {
    errdefer std.debug.print("zom.lint:   case: {s}\n", .{label});
    const rows = try rel.toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);

    var buf: [users.len]?u8 = undefined;
    if (rows.len != want.len) {
        std.debug.print("zom.lint:   expected {d} rows, found {d}\n", .{ want.len, rows.len });
        return error.TestExpectedEqual;
    }
    for (rows, buf[0..rows.len]) |row, *age| age.* = row.age;
    try testing.expectEqualDeep(want, buf[0..rows.len]);
    try expectCount(rel, rows.len);
}

fn byId(_: void, a: User, b: User) bool {
    return a.id < b.id;
}

/// Reads every row of `rel` and compares them, sorted by id, with `want`
/// (in any order), checking `count` too.
fn expectRows(rel: anytype, label: []const u8, want: []const User) !void {
    errdefer std.debug.print("zom.lint:   case: {s}\n", .{label});
    const rows = try rel.toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);
    std.mem.sort(User, rows, {}, byId);

    var buf: [users.len + 4]User = undefined;
    if (want.len > buf.len) unreachable; // a lint bug, not an adapter one
    const sorted = buf[0..want.len];
    @memcpy(sorted, want);
    std.mem.sort(User, sorted, {}, byId);

    try testing.expectEqualDeep(@as([]const User, sorted), @as([]const User, rows));
    try expectCount(rel, rows.len);
}

/// The seed rows with `extra` appended, for `expectRows`.
fn seededPlus(buf: *[users.len + 4]User, extra: []const User) []const User {
    @memcpy(buf[0..users.len], &users);
    @memcpy(buf[users.len..][0..extra.len], extra);
    return buf[0 .. users.len + extra.len];
}

/// Checks that `result` is exactly `want`, one of the shared names in
/// `zom.adapter.Error`. Fails, saying why, when the call succeeded, returned
/// another error, or when its error set cannot hold `want` at all (checked
/// at compile time from the error set's members, unless it is `anyerror`).
pub fn expectSharedError(label: []const u8, comptime want: adapter.Error, result: anytype) !void {
    const R = @TypeOf(result);
    const E = switch (@typeInfo(R)) {
        .error_union => |u| u.error_set,
        .error_set => R,
        else => @compileError("zom.lint: expectSharedError takes an error union, found " ++ @typeName(R)),
    };
    const name = @errorName(want);
    const declared = comptime blk: {
        const set = @typeInfo(E).error_set.error_names orelse break :blk true; // anyerror
        for (set) |e| if (std.mem.eql(u8, e, name)) break :blk true;
        break :blk false;
    };
    if (!declared) {
        const members = comptime blk: {
            var out: []const u8 = "";
            for (@typeInfo(E).error_set.error_names.?, 0..) |e, i| out = out ++ (if (i == 0) "" else ", ") ++ e;
            break :blk out;
        };
        std.debug.print("zom.lint:   case: {s}: the call cannot return error.{s} (its errors: {s}); " ++
            "the adapter must use the shared name from zom.adapter.Error\n", .{ label, name, members });
        return error.TestUnexpectedError;
    }
    if (result) |_| {
        std.debug.print("zom.lint:   case: {s}: expected error.{s}, the call succeeded\n", .{ label, name });
        return error.TestExpectedError;
    } else |err| if (err != want) {
        std.debug.print("zom.lint:   case: {s}: expected error.{s} (the shared name in zom.adapter.Error), found error.{t}\n", .{ label, name, err });
        return error.TestUnexpectedError;
    }
}

// -- checks ----------------------------------------------------------------

fn checkReadAll(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    const rows = try rel.toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);
    std.mem.sort(User, rows, {}, struct {
        fn lessThan(_: void, a: User, b: User) bool {
            return a.id < b.id;
        }
    }.lessThan);

    var want = users;
    std.mem.sort(User, &want, {}, struct {
        fn lessThan(_: void, a: User, b: User) bool {
            return a.id < b.id;
        }
    }.lessThan);
    try testing.expectEqualDeep(@as([]const User, &want), @as([]const User, rows));
    try expectCount(rel, users.len);
}

/// A driver may hand out rows that point into a buffer reused by the next
/// row or the next query (pg.zig does). The strings a read returns must be
/// copies that outlive both.
fn checkReadStrings(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();
    const a = testing.allocator;

    const by_id = rel.order(.id, .asc);
    const first = try by_id.toSlice(a);
    defer rel.free(a, first);
    // Other reads in between, of other strings.
    const desc = try rel.order(.id, .desc).toSlice(a);
    rel.free(a, desc);
    if (try rel.byPk(5).one(a)) |u| rel.freeOne(a, u);

    errdefer std.debug.print("zom.lint:   case: names of a read, after two more reads\n", .{});
    const want = [_][]const u8{ "dee", "ada", "fay", "bob", "eve", "cy" };
    try testing.expectEqual(want.len, first.len);
    for (first, want) |row, name| try testing.expectEqualStrings(name, row.name);
}

fn checkIntOps(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.where(.id, .eq, 3), "id eq 3", .any, &.{3});
    try expectIds(rel.where(.id, .neq, 3), "id neq 3", .any, &.{ 1, 2, 4, 5, 6 });
    try expectIds(rel.where(.id, .lt, 3), "id lt 3", .any, &.{ 1, 2 });
    try expectIds(rel.where(.id, .lte, 3), "id lte 3", .any, &.{ 1, 2, 3 });
    try expectIds(rel.where(.id, .gt, 3), "id gt 3", .any, &.{ 4, 5, 6 });
    try expectIds(rel.where(.id, .gte, 3), "id gte 3", .any, &.{ 3, 4, 5, 6 });
    try expectIds(rel.where(.id, .eq, 99), "id eq 99 (no match)", .any, &.{});

    // On a nullable attribute, rows holding null never match a comparison
    // with a value, neq included (SQL: NULL <> 25 is not true).
    try expectIds(rel.where(.age, .eq, 17), "age eq 17", .any, &.{3});
    try expectIds(rel.where(.age, .neq, 25), "age neq 25", .any, &.{ 1, 3, 4 });
    try expectIds(rel.where(.age, .lt, 30), "age lt 30", .any, &.{ 3, 6 });
    try expectIds(rel.where(.age, .lte, 25), "age lte 25", .any, &.{ 3, 6 });
    try expectIds(rel.where(.age, .gt, 36), "age gt 36", .any, &.{4});
    try expectIds(rel.where(.age, .gte, 36), "age gte 36", .any, &.{ 1, 4 });

    try expectIds(rel.where(.id, .gt, 1).where(.age, .lt, 40), "id gt 1 and age lt 40", .any, &.{ 3, 6 });
}

fn checkStringOps(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.where(.name, .eq, "fay"), "name eq \"fay\"", .any, &.{3});
    try expectIds(rel.where(.name, .neq, "fay"), "name neq \"fay\"", .any, &.{ 1, 2, 4, 5, 6 });
    try expectIds(rel.where(.name, .eq, "zed"), "name eq \"zed\" (no match)", .any, &.{});
    try expectIds(rel.where(.name, .eq, "fa"), "name eq \"fa\" (a prefix is not equal)", .any, &.{});
    try expectIds(rel.where(.role, .eq, .b), "role eq .b", .any, &.{ 2, 5 });
    try expectIds(rel.where(.role, .neq, .a), "role neq .a", .any, &.{ 2, 3, 5, 6 });
}

fn checkNulls(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.where(.age, .eq, null), "age eq null (IS NULL)", .any, &.{ 2, 5 });
    try expectIds(rel.where(.age, .neq, null), "age neq null (IS NOT NULL)", .any, &.{ 1, 3, 4, 6 });
    try expectIds(rel.where(.age, .lt, null), "age lt null (matches nothing)", .any, &.{});
    try expectIds(rel.where(.age, .lte, null), "age lte null (matches nothing)", .any, &.{});
    try expectIds(rel.where(.age, .gt, null), "age gt null (matches nothing)", .any, &.{});
    try expectIds(rel.where(.age, .gte, null), "age gte null (matches nothing)", .any, &.{});
    try expectIds(rel.where(.age, .is_null, {}), "age is_null", .any, &.{ 2, 5 });
    try expectIds(rel.where(.age, .is_not_null, {}), "age is_not_null", .any, &.{ 1, 3, 4, 6 });
}

fn checkIn(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.where(.id, .in, .{ 1, 3, 5 }), "id in (1, 3, 5)", .any, &.{ 1, 3, 5 });
    try expectIds(rel.where(.id, .in, .{ 3, 99 }), "id in (3, 99)", .any, &.{3});
    try expectIds(rel.where(.id, .in, .{}), "id in () (matches nothing)", .any, &.{});
    try expectIds(rel.where(.id, .not_in, .{ 1, 3, 5 }), "id not_in (1, 3, 5)", .any, &.{ 2, 4, 6 });
    try expectIds(rel.where(.id, .not_in, .{}), "id not_in () (every row)", .any, &.{ 1, 2, 3, 4, 5, 6 });
    try expectIds(rel.where(.name, .in, .{ "ada", "zed", "fa" }), "name in (\"ada\", \"zed\", \"fa\")", .any, &.{2});
    try expectIds(rel.where(.role, .in, .{ .a, .c }), "role in (.a, .c)", .any, &.{ 1, 3, 4, 6 });
    try expectIds(rel.where(.role, .not_in, .{.a}), "role not_in (.a)", .any, &.{ 2, 3, 5, 6 });

    // SQL null semantics: a null attribute is never in or not in a list, a
    // null in the list equals nothing, and makes not_in match nothing.
    try expectIds(rel.where(.age, .in, .{ 17, 52 }), "age in (17, 52)", .any, &.{ 3, 4 });
    try expectIds(rel.where(.age, .not_in, .{17}), "age not_in (17) (nulls excluded)", .any, &.{ 1, 4, 6 });
    try expectIds(rel.where(.age, .in, .{ 17, null }), "age in (17, null)", .any, &.{3});
    try expectIds(rel.where(.age, .not_in, .{ 17, null }), "age not_in (17, null) (matches nothing)", .any, &.{});

    var keys = [_]u32{ 6, 2, 99 };
    try expectIds(rel.whereIn(.id, &keys), "whereIn id [6, 2, 99]", .any, &.{ 2, 6 });
    try expectIds(rel.whereNotIn(.id, &keys), "whereNotIn id [6, 2, 99]", .any, &.{ 1, 3, 4, 5 });
    try expectIds(rel.whereIn(.id, keys[0..0]), "whereIn id [] (matches nothing)", .any, &.{});
    const roles = [_]Role{.b};
    try expectIds(rel.whereIn(.role, &roles), "whereIn role [.b]", .any, &.{ 2, 5 });
    try expectIds(rel.whereIn(.id, &keys).order(.id, .desc).limit(1), "whereIn id, order id desc, limit 1", .as_read, &.{6});
}

fn checkLike(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.where(.name, .like, "a%"), "name like \"a%\"", .any, &.{2});
    try expectIds(rel.where(.name, .like, "%e%"), "name like \"%e%\"", .any, &.{ 1, 5 });
    try expectIds(rel.where(.name, .like, "_y"), "name like \"_y\"", .any, &.{6});
    try expectIds(rel.where(.name, .like, "___"), "name like \"___\"", .any, &.{ 1, 2, 3, 4, 5 });
    try expectIds(rel.where(.name, .like, "%"), "name like \"%\" (every row)", .any, &.{ 1, 2, 3, 4, 5, 6 });
    try expectIds(rel.where(.name, .like, ""), "name like \"\" (no empty names)", .any, &.{});
    try expectIds(rel.where(.name, .like, "fay"), "name like \"fay\" (no wildcard)", .any, &.{3});
    try expectIds(rel.where(.name, .like, "fa_"), "name like \"fa_\"", .any, &.{3});
    try expectIds(rel.where(.name, .like, "fa\\_"), "name like \"fa\\_\" (escaped _ is literal)", .any, &.{});
    try expectIds(rel.where(.name, .like, "%\\%"), "name like \"%\\%\" (escaped % is literal)", .any, &.{});
    try expectIds(rel.where(.name, .like, "A%"), "name like \"A%\" (case-sensitive)", .any, &.{});
    try expectIds(rel.where(.name, .ilike, "A%"), "name ilike \"A%\"", .any, &.{2});
    try expectIds(rel.where(.name, .ilike, "%E"), "name ilike \"%E\"", .any, &.{ 1, 5 });
}

fn checkBetween(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.where(.id, .between, .{ 2, 4 }), "id between 2 and 4", .any, &.{ 2, 3, 4 });
    try expectIds(rel.where(.id, .between, .{ 3, 3 }), "id between 3 and 3", .any, &.{3});
    try expectIds(rel.where(.id, .between, .{ 4, 2 }), "id between 4 and 2 (lo > hi, empty)", .any, &.{});
    try expectIds(rel.where(.age, .between, .{ 17, 36 }), "age between 17 and 36 (nulls excluded)", .any, &.{ 1, 3, 6 });
    try expectIds(rel.where(.name, .between, .{ "b", "d" }), "name between \"b\" and \"d\"", .any, &.{ 4, 6 });
    try expectIds(rel.where(.role, .between, .{ .a, .b }), "role between .a and .b (declaration order)", .any, &.{ 1, 2, 4, 5 });
}

fn checkBoolean(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    const any = query.any;
    const all = query.all;
    const not = query.not;

    try expectIds(rel.whereAny(.{ .{ .age, .gt, 40 }, .{ .role, .eq, .b } }), "age gt 40 or role eq .b", .any, &.{ 2, 4, 5 });
    try expectIds(rel.whereAny(.{ .{ .age, .gt, 40 }, .{ .role, .eq, .b } }).where(.id, .neq, 5), "(age gt 40 or role eq .b) and id neq 5", .any, &.{ 2, 4 });
    try expectIds(rel.whereAny(.{.{ .id, .eq, 3 }}), "any with one condition", .any, &.{3});
    try expectIds(
        rel.whereAny(.{ all(.{ .{ .role, .eq, .a }, .{ .age, .lt, 40 } }), .{ .id, .eq, 2 } }),
        "(role eq .a and age lt 40) or id eq 2",
        .any,
        &.{ 1, 2 },
    );

    // NOT of an unknown is unknown, so a null age matches neither
    // `age gt 30` nor its negation.
    try expectIds(rel.whereNot(.{ .age, .gt, 30 }), "not age gt 30 (nulls excluded)", .any, &.{ 3, 6 });
    try expectIds(rel.whereNot(.{ .age, .is_null, {} }), "not age is_null", .any, &.{ 1, 3, 4, 6 });
    try expectIds(rel.whereNot(not(.{ .age, .gt, 30 })), "not not age gt 30", .any, &.{ 1, 4 });
    // Unknown OR false is unknown (ids 2, 5); unknown OR true is true.
    try expectIds(rel.whereNot(any(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .a } })), "not (age gt 30 or role eq .a)", .any, &.{ 3, 6 });
    try expectIds(rel.whereNot(any(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .b } })), "not (age gt 30 or role eq .b)", .any, &.{ 3, 6 });
    // Unknown AND false is false (id 2, 5 are role .b), so NOT is true.
    try expectIds(rel.whereNot(all(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .a } })), "not (age gt 30 and role eq .a)", .any, &.{ 2, 3, 5, 6 });

    try expectIds(
        rel.whereAny(.{ .{ .age, .gt, 40 }, .{ .role, .eq, .b } }).order(.id, .desc).limit(2),
        "(age gt 40 or role eq .b), order id desc, limit 2",
        .as_read,
        &.{ 5, 4 },
    );
}

fn checkOrderPk(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.order(.id, .asc), "order id asc", .as_read, &.{ 1, 2, 3, 4, 5, 6 });
    try expectIds(rel.order(.id, .desc), "order id desc", .as_read, &.{ 6, 5, 4, 3, 2, 1 });
    try expectIds(rel.where(.role, .neq, .b).order(.id, .desc), "role neq .b, order id desc", .as_read, &.{ 6, 4, 3, 1 });
}

fn checkOrderOn(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try expectIds(rel.order(.name, .asc), "order name asc", .as_read, &.{ 2, 4, 6, 1, 5, 3 });
    try expectIds(rel.order(.name, .desc), "order name desc", .as_read, &.{ 3, 5, 1, 6, 4, 2 });
    try expectAges(rel.order(.age, .asc), "order age asc (nulls last)", &.{ 17, 25, 36, 52, null, null });
    try expectAges(rel.order(.age, .desc), "order age desc (nulls first)", &.{ null, null, 52, 36, 25, 17 });

    // Several keys: each breaks the ties left by the ones before it, with
    // nulls in the first key (ids 2, 5) and ties on it (role).
    try expectIds(rel.order(.role, .asc).order(.age, .asc), "order role asc, age asc", .as_read, &.{ 1, 4, 2, 5, 3, 6 });
    try expectIds(rel.order(.role, .desc).order(.age, .desc).order(.id, .desc), "order role desc, age desc, id desc", .as_read, &.{ 6, 3, 5, 2, 4, 1 });
    try expectIds(rel.order(.age, .asc).order(.id, .desc), "order age asc, id desc (nulls last)", .as_read, &.{ 3, 6, 1, 4, 5, 2 });
    try expectIds(rel.order(.age, .desc).order(.id, .asc), "order age desc, id asc (nulls first)", .as_read, &.{ 2, 5, 4, 1, 6, 3 });
    try expectIds(rel.order(.id, .desc).reorder(.{ .{ .role, .asc }, .{ .name, .desc } }), "reorder role asc, name desc", .as_read, &.{ 1, 4, 5, 2, 3, 6 });
}

fn checkLimit(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();
    const by_id = rel.order(.id, .asc);

    try expectIds(by_id.limit(2), "limit 2", .as_read, &.{ 1, 2 });
    try expectIds(by_id.limit(6), "limit 6 (every row)", .as_read, &.{ 1, 2, 3, 4, 5, 6 });
    try expectIds(by_id.limit(100), "limit 100 (past the end)", .as_read, &.{ 1, 2, 3, 4, 5, 6 });
    try expectIds(by_id.limit(0), "limit 0", .as_read, &.{});
    try expectIds(by_id.where(.role, .eq, .c).limit(1), "role eq .c, limit 1", .as_read, &.{3});

    // Without an order the rows are unspecified, but not how many.
    const rows = try rel.limit(4).toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 4), rows.len);
    try expectCount(rel.limit(4), 4);
}

fn checkOffset(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();
    const by_id = rel.order(.id, .asc);

    try expectIds(by_id.offset(0), "offset 0", .as_read, &.{ 1, 2, 3, 4, 5, 6 });
    try expectIds(by_id.offset(2), "offset 2", .as_read, &.{ 3, 4, 5, 6 });
    try expectIds(by_id.offset(5), "offset 5 (last row)", .as_read, &.{6});
    try expectIds(by_id.offset(6), "offset 6 (at the end, empty)", .as_read, &.{});
    try expectIds(by_id.offset(100), "offset 100 (past the end, empty)", .as_read, &.{});
    try expectIds(by_id.limit(2).offset(2), "limit 2 offset 2", .as_read, &.{ 3, 4 });
    try expectIds(by_id.limit(3).offset(4), "limit 3 offset 4 (runs past the end)", .as_read, &.{ 5, 6 });
    try expectIds(by_id.limit(0).offset(2), "limit 0 offset 2", .as_read, &.{});
    try expectIds(by_id.where(.age, .neq, null).limit(2).offset(1), "age neq null, limit 2 offset 1", .as_read, &.{ 3, 4 });
    try expectIds(rel.order(.id, .desc).offset(4), "order id desc, offset 4", .as_read, &.{ 2, 1 });
}

fn checkOne(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();
    const a = testing.allocator;

    const found = (try rel.byPk(3).one(a)) orelse return error.TestExpectedOneTuple;
    defer rel.freeOne(a, found);
    try testing.expectEqualDeep(User{ .id = 3, .name = "fay", .age = 17, .role = .c }, found);
    try testing.expectEqual(@as(?User, null), try rel.byPk(99).one(a));
    const six = (try rel.where(.id, .gt, 5).one(a)) orelse return error.TestExpectedOneTuple;
    defer rel.freeOne(a, six);
    try testing.expectEqual(@as(u32, 6), six.id);
    const first = (try rel.order(.id, .asc).first(a)) orelse return error.TestExpectedOneTuple;
    defer rel.freeOne(a, first);
    try testing.expectEqualStrings("dee", first.name);
    try testing.expectError(error.MoreThanOneTuple, rel.where(.role, .eq, .a).one(a));
    try testing.expectError(error.MoreThanOneTuple, rel.one(a));
}

fn checkProjection(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    // Filtered and ordered on `age`, which is not selected.
    try expectNames(rel.where(.age, .gt, 20).order(.age, .desc).select(.{ .name, .role }), "age gt 20, order age desc, select name, role", &.{ "bob", "dee", "cy" });
    try expectNames(rel.order(.id, .asc).limit(2).select(.{.name}), "order id asc, limit 2, select name", &.{ "dee", "ada" });
    try expectNames(rel.where(.role, .eq, .b).order(.name, .desc).select(.{ .role, .name }), "role eq .b, order name desc, select role, name", &.{ "eve", "ada" });
    try expectNames(rel.where(.id, .gt, 99).select(.{.name}), "nothing matches", &.{});
}

/// Reads the projected relation `rel` and checks its names, in order.
fn expectNames(rel: anytype, label: []const u8, want: []const []const u8) !void {
    errdefer std.debug.print("zom.lint:   case: {s}\n", .{label});
    const rows = try rel.toSlice(testing.allocator);
    defer rel.free(testing.allocator, rows);
    if (rows.len != want.len) {
        std.debug.print("zom.lint:   expected {d} rows, found {d}\n", .{ want.len, rows.len });
        return error.TestExpectedEqual;
    }
    for (rows, want) |row, name| try testing.expectEqualStrings(name, row.name);
    try expectCount(rel, rows.len);
}

fn checkJoin(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();
    try Fixture(G, F).seed(&fx.gateway, Posts, &posts);
    const post_rel = try RelationOf(Posts, G).init(&fx.gateway);

    try expectIds(rel.join(.posts), "join posts: bob once, though he has two", .any, &.{ 2, 4, 6 });
    try expectIds(rel.join(.posts).whereJoined(.posts, .published, .eq, true), "join posts, published", .any, &.{ 4, 6 });
    try expectIds(rel.join(.posts).whereJoined(.posts, .title, .eq, "b2"), "join posts, title eq b2", .any, &.{4});
    try expectIds(rel.where(.age, .gt, 30).join(.posts), "age gt 30 (bob, dee), join posts", .any, &.{4});
    try expectIds(rel.join(.posts).order(.id, .asc).limit(2), "join posts, order id asc, limit 2", .as_read, &.{ 2, 4 });
    try expectIds(post_rel.join(.author).whereJoined(.author, .role, .eq, .a), "posts join author, role eq .a", .any, &.{ 20, 21 });

    // Two joins: every one must match, each with its own joined row.
    try Fixture(G, F).seed(&fx.gateway, Comments, &comments);
    try expectIds(rel.join(.comments), "join comments: bob once, though he has two", .any, &.{ 1, 2, 4 });
    try expectIds(rel.join(.posts).join(.comments), "join posts, join comments", .any, &.{ 2, 4 });
    try expectIds(rel.join(.comments).join(.posts), "join comments, join posts", .any, &.{ 2, 4 });
    try expectIds(
        rel.join(.posts).whereJoined(.posts, .published, .eq, true).join(.comments),
        "join posts, published, join comments",
        .any,
        &.{4},
    );
    try expectIds(
        rel.join(.posts).join(.comments).whereJoined(.comments, .flagged, .eq, true),
        "join posts, join comments, flagged",
        .any,
        &.{2},
    );
    try expectIds(
        rel.join(.posts).join(.comments).whereJoined(.posts, .published, .eq, true).whereJoined(.comments, .flagged, .eq, true),
        "join posts, published, join comments, flagged: no one has both",
        .any,
        &.{},
    );
    try expectIds(rel.where(.role, .eq, .a).join(.posts).join(.comments), "role eq .a (bob, dee), join posts, join comments", .any, &.{4});
    try expectIds(rel.join(.posts).join(.comments).order(.id, .asc).limit(1), "join posts, join comments, order id asc, limit 1", .as_read, &.{2});
}

/// Reads `rel` (whose query has `per_group` set) and checks it against
/// the in-memory page: every tuple of the same query without its limit
/// and offset, read through `tuples` (a relation over the same dataset),
/// cut by `Query.pageGroups`. Ids are compared in the order read, so the
/// query must end its order with a unique key.
fn expectPerGroup(rel: anytype, tuples: anytype, label: []const u8) !void {
    errdefer std.debug.print("zom.lint:   case: {s}\n", .{label});
    const got = try rel.toSlice(testing.allocator);
    defer rel.free(testing.allocator, got);

    var whole = tuples;
    whole.query = rel.query;
    whole.query.limit = null;
    whole.query.offset = 0;
    whole.query.per_group = null;
    const all = try whole.toSlice(testing.allocator);
    defer whole.free(testing.allocator, all);
    // `pageGroups` moves the rows it keeps to the front of a copy; the
    // strings stay `all`'s.
    const copy = try testing.allocator.dupe(User, all);
    defer testing.allocator.free(copy);
    const want = try rel.query.pageGroups(copy, testing.allocator);

    var want_ids: [users.len]u32 = undefined;
    var got_ids: [users.len]u32 = undefined;
    if (got.len > users.len) {
        std.debug.print("zom.lint:   read returned {d} rows, only {d} are seeded\n", .{ got.len, users.len });
        return error.TestUnexpectedResult;
    }
    for (want, want_ids[0..want.len]) |row, *id| id.* = row.id;
    for (got, got_ids[0..got.len]) |row, *id| id.* = row.id;
    try testing.expectEqualSlices(u32, want_ids[0..want.len], got_ids[0..got.len]);
}

fn checkPerGroup(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    const Case = struct { label: []const u8, field: Fixture(G, F).Relation.Field, limit: ?usize, offset: usize };
    // By role: a = {4, 1}, b = {2, 5}, c = {6, 3}. By age: ada and eve
    // (null) are one group, everyone else is alone.
    const cases = [_]Case{
        .{ .label = "role, limit 1", .field = .role, .limit = 1, .offset = 0 },
        .{ .label = "role, offset 1", .field = .role, .limit = null, .offset = 1 },
        .{ .label = "role, offset 1, limit 1", .field = .role, .limit = 1, .offset = 1 },
        .{ .label = "role, offset past every group", .field = .role, .limit = 3, .offset = 2 },
        .{ .label = "role, limit 0", .field = .role, .limit = 0, .offset = 0 },
        .{ .label = "role, limit past every group", .field = .role, .limit = 10, .offset = 0 },
        .{ .label = "age (nulls are one group), limit 1", .field = .age, .limit = 1, .offset = 0 },
        .{ .label = "name (every row alone), offset 1", .field = .name, .limit = null, .offset = 1 },
    };
    inline for (.{ .asc, .desc }) |dir| {
        for (cases) |c| {
            var r = rel.order(.id, dir);
            r.query.limit = c.limit;
            r.query.offset = c.offset;
            r.query.per_group = c.field;
            try expectPerGroup(r, rel, c.label);
        }
    }

    // After a filter: rows it drops don't count toward a group's page.
    var filtered = rel.where(.age, .lt, 50).order(.name, .asc).order(.id, .asc).limit(1);
    filtered.query.per_group = .role;
    try expectPerGroup(filtered, rel, "age lt 50 (not bob), role, order name, limit 1");

    // `in`, as combine's batched `whereIn` sends it.
    if (comptime adapter.Adapter(G).supports(Users).in) {
        var batch = rel.where(.role, .in, .{ .a, .c }).order(.id, .desc).limit(1);
        batch.query.per_group = .role;
        try expectPerGroup(batch, rel, "role in (a, c), order id desc, limit 1");
    }

    // A projection reads the same page.
    if (comptime adapter.Adapter(G).supports(Users).projection) {
        var projected = rel.select(.{ .id, .name }).order(.id, .desc).limit(1);
        projected.query.per_group = .role;
        try expectPerGroup(projected, rel, "select id, name; role, limit 1");
    }
}

fn checkInsert(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    const new: User = .{ .id = 7, .name = "gus", .age = null, .role = .b };
    const stored = try rel.create(new).commitAlloc(testing.allocator);
    defer rel.freeOne(testing.allocator, stored);
    try testing.expectEqualDeep(new, stored);
    var buf: [users.len + 4]User = undefined;
    try expectRows(rel, "after inserting id 7", seededPlus(&buf, &.{new}));

    const clash: User = .{ .id = 3, .name = "zed", .age = 1, .role = .a };
    try expectSharedError("insert an existing key", error.DuplicatePrimaryKey, rel.create(clash).commitAlloc(testing.allocator));
    try expectRows(rel, "a failed insert changes nothing", seededPlus(&buf, &.{new}));
}

/// The guarantee from issue #3: an adapter keeps its own copy of every
/// string, so the caller's buffer can be freed after the write.
fn checkInsertCopies(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();
    const a = testing.allocator;

    // The buffer is overwritten, as if freed and reused, and only freed
    // after the checks: reading truly freed memory would crash the whole
    // test binary instead of failing this check.
    const heap = try a.dupe(u8, "gus");
    defer a.free(heap);
    const returned = try rel.create(.{ .id = 7, .name = heap, .age = 40, .role = .c }).commitAlloc(a);
    defer rel.freeOne(a, returned);
    @memset(heap, '?');

    errdefer std.debug.print("zom.lint:   case: a string inserted from an overwritten buffer\n", .{});
    try testing.expectEqualStrings("gus", returned.name);
    const stored = (try rel.byPk(7).one(a)) orelse return error.TestExpectedOneTuple;
    defer rel.freeOne(a, stored);
    try testing.expectEqualStrings("gus", stored.name);
}

fn checkInsertMany(comptime G: type, comptime F: type) !void {
    const A = adapter.Adapter(G);
    const on_duplicate: OnDuplicate = comptime if (@hasDecl(F, "insert_many_on_duplicate"))
        F.insert_many_on_duplicate
    else if (A.has(Users, .batch_insert)) .stores_nothing else .stores_prefix;
    var buf: [users.len + 4]User = undefined;

    const seven: User = .{ .id = 7, .name = "gus", .age = 40, .role = .c };
    const eight: User = .{ .id = 8, .name = "hal", .age = null, .role = .a };
    const nine: User = .{ .id = 9, .name = "ivy", .age = 9, .role = .b };
    {
        var fx: Fixture(G, F) = undefined;
        const rel = try fx.init();
        defer fx.deinit();
        try testing.expectEqual(@as(usize, 3), try rel.createMany(&.{ seven, eight, nine }).commit());
        try expectRows(rel, "after inserting 7, 8, 9", seededPlus(&buf, &.{ seven, eight, nine }));
        try testing.expectEqual(@as(usize, 0), try rel.createMany(&.{}).commit());
        try expectRows(rel, "an empty batch stores nothing", seededPlus(&buf, &.{ seven, eight, nine }));
    }
    {
        // Strings in a batch are copied too.
        var fx: Fixture(G, F) = undefined;
        const rel = try fx.init();
        defer fx.deinit();
        const heap = try testing.allocator.dupe(u8, "gus");
        defer testing.allocator.free(heap);
        try testing.expectEqual(@as(usize, 1), try rel.createMany(&.{.{ .id = 7, .name = heap, .age = 40, .role = .c }}).commit());
        @memset(heap, '?');
        try expectRows(rel, "a batch string from an overwritten buffer", seededPlus(&buf, &.{seven}));
    }
    {
        var fx: Fixture(G, F) = undefined;
        const rel = try fx.init();
        defer fx.deinit();
        const clash: User = .{ .id = 1, .name = "zed", .age = 1, .role = .a };
        try expectSharedError("a batch with a stored key", error.DuplicatePrimaryKey, rel.createMany(&.{ seven, eight, clash, nine }).commit());
        const want = switch (on_duplicate) {
            .stores_nothing => seededPlus(&buf, &.{}),
            .stores_prefix => seededPlus(&buf, &.{ seven, eight }),
        };
        try expectRows(rel, std.fmt.comptimePrint("after a batch with a stored key ({t})", .{on_duplicate}), want);
    }
    {
        var fx: Fixture(G, F) = undefined;
        const rel = try fx.init();
        defer fx.deinit();
        const again: User = .{ .id = 7, .name = "zed", .age = 1, .role = .a };
        try expectSharedError("a batch with the same key twice", error.DuplicatePrimaryKey, rel.createMany(&.{ seven, again }).commit());
        const want = switch (on_duplicate) {
            .stores_nothing => seededPlus(&buf, &.{}),
            .stores_prefix => seededPlus(&buf, &.{seven}),
        };
        try expectRows(rel, std.fmt.comptimePrint("after a batch with the same key twice ({t})", .{on_duplicate}), want);
    }
}

fn checkUpdate(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();
    const a = testing.allocator;

    var want = users;
    try testing.expectEqual(@as(usize, 2), try rel.where(.role, .eq, .a).update().set(.age, 40).commit());
    for (&want) |*u| if (u.role == .a) {
        u.age = 40;
    };
    try expectRows(rel, "set age 40 where role eq .a", &want);

    try testing.expectEqual(@as(usize, 0), try rel.where(.id, .eq, 99).update().set(.age, 1).commit());
    try expectRows(rel, "an update matching nothing", &want);

    try testing.expectEqual(@as(usize, 0), try rel.byPk(3).update().commit());
    try expectRows(rel, "an update with zero changes", &want);

    // Strings set by an update are copied too.
    const heap = try a.dupe(u8, "fae");
    defer a.free(heap);
    try testing.expectEqual(@as(usize, 1), try rel.byPk(3).update().set(.name, @as([]const u8, heap)).commit());
    @memset(heap, '?');
    want[5].name = "fae";
    try expectRows(rel, "set name from an overwritten buffer", &want);

    try expectSharedError("set the key to one in use", error.DuplicatePrimaryKey, rel.byPk(1).update().set(.id, 2).commit());
    try expectRows(rel, "a key clash changes nothing", &want);
    try expectSharedError("set the same key on several rows", error.DuplicatePrimaryKey, rel.where(.role, .eq, .b).update().set(.id, 50).commit());
    try expectRows(rel, "a key set on several rows changes nothing", &want);

    var too_big: u32 = 300;
    _ = &too_big;
    try expectSharedError("set age (?u8) to a runtime 300", error.ValueOutOfRange, rel.byPk(1).update().set(.name, "zed").set(.age, too_big).commit());
    try expectRows(rel, "an out-of-range value changes nothing", &want);

    // Changing the key to an unused one works, and moves the row.
    try testing.expectEqual(@as(usize, 1), try rel.byPk(1).update().set(.id, 10).commit());
    want[1].id = 10;
    try expectRows(rel, "set id 1 to 10", &want);
    if (try rel.byPk(1).one(a)) |u| {
        rel.freeOne(a, u);
        return error.TestExpectedNull;
    }
}

fn checkDelete(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    try testing.expectEqual(@as(usize, 2), try rel.where(.role, .eq, .c).delete());
    try expectRows(rel, "after deleting role eq .c", &.{ users[0], users[1], users[3], users[4] });
    try expectIds(rel.where(.role, .eq, .c), "deleted rows are gone", .any, &.{});

    try testing.expectEqual(@as(usize, 0), try rel.where(.id, .eq, 99).delete());
    try testing.expectEqual(@as(usize, 0), try rel.where(.role, .eq, .c).delete());
    try expectRows(rel, "a delete matching nothing", &.{ users[0], users[1], users[3], users[4] });

    try testing.expectEqual(@as(usize, 1), try rel.byPk(4).delete());
    try expectIds(rel, "after deleting id 4", .any, &.{ 1, 2, 5 });

    try testing.expectEqual(@as(usize, 3), try rel.delete());
    try expectIds(rel, "after deleting everything", .any, &.{});
}
