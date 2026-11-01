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

const std = @import("std");
const testing = std.testing;
const adapter = @import("adapter.zig");
const Schema = @import("schema.zig").Schema;
const RelationOf = @import("relation.zig").Relation;

pub const Role = enum { a, b, c };

pub const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    role: Role,
};

pub const Users = Schema(User, "lint_users", .id);

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
};

const checks = .{
    .{ Check{ .name = "read: no filters returns every row" }, checkReadAll },
    .{ Check{ .name = "filter: every op on an int attribute" }, checkIntOps },
    .{ Check{ .name = "filter: eq/neq on string and enum attributes" }, checkStringOps },
    .{ Check{ .name = "filter: null semantics" }, checkNulls },
    .{ Check{ .name = "filter: in / not_in, from a tuple and from a slice", .features = &.{"in"} }, checkIn },
    .{ Check{ .name = "filter: like / ilike", .features = &.{"like"} }, checkLike },
    .{ Check{ .name = "filter: between, inclusive" }, checkBetween },
    .{ Check{ .name = "order: on the primary key" }, checkOrderPk },
    .{ Check{ .name = "order: on other attributes, nulls last on asc", .features = &.{"order_on"} }, checkOrderOn },
    .{ Check{ .name = "limit" }, checkLimit },
    .{ Check{ .name = "offset", .features = &.{"offset"} }, checkOffset },
    .{ Check{ .name = "one: null, one tuple, or error.MoreThanOneTuple" }, checkOne },
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

fn skipReason(comptime A: type, comptime c: Check) ?[]const u8 {
    // Checking the dataset contract for every entry in `checks` adds up.
    @setEvalBranchQuota(10_000);
    for (c.needs) |cap| {
        if (!A.has(Users, cap))
            return std.fmt.comptimePrint("dataset has no `{t}` capability", .{cap});
    }
    if (c.needs_any.len > 0) {
        for (c.needs_any) |cap| {
            if (A.has(Users, cap)) break;
        } else {
            var tags: []const u8 = "";
            for (c.needs_any, 0..) |cap, i| tags = tags ++ (if (i == 0) "" else " or ") ++ "`" ++ @tagName(cap) ++ "`";
            return "dataset has no " ++ tags ++ " capability";
        }
    }
    const s = A.supports(Users);
    for (c.features) |f| {
        if (!@field(s, f))
            return std.fmt.comptimePrint("dataset does not support `{s}`", .{f});
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
            try seed(&self.gateway, &users);
            return Relation.init(&self.gateway);
        }

        fn deinit(self: *Self) void {
            F.destroy(&self.gateway);
        }

        fn seed(g: *G, rows: []const User) !void {
            if (@hasDecl(F, "seed")) return F.seed(g, Users, rows);
            const A = adapter.Adapter(G);
            const d = try g.dataset(Users);
            if (comptime A.has(Users, .batch_insert)) {
                try testing.expectEqual(rows.len, try d.insertMany(rows));
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
    defer testing.allocator.free(rows);

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
    defer testing.allocator.free(rows);

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
    defer testing.allocator.free(rows);
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
        const set = @typeInfo(E).error_set orelse break :blk true; // anyerror
        for (set) |e| if (std.mem.eql(u8, e.name, name)) break :blk true;
        break :blk false;
    };
    if (!declared) {
        const members = comptime blk: {
            var out: []const u8 = "";
            for (@typeInfo(E).error_set.?, 0..) |e, i| out = out ++ (if (i == 0) "" else ", ") ++ e.name;
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
    defer testing.allocator.free(rows);
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
    defer testing.allocator.free(rows);
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
    try testing.expectEqualDeep(User{ .id = 3, .name = "fay", .age = 17, .role = .c }, found);
    try testing.expectEqual(@as(?User, null), try rel.byPk(99).one(a));
    try testing.expectEqual(@as(u32, 6), ((try rel.where(.id, .gt, 5).one(a)) orelse return error.TestExpectedOneTuple).id);
    try testing.expectError(error.MoreThanOneTuple, rel.where(.role, .eq, .a).one(a));
    try testing.expectError(error.MoreThanOneTuple, rel.one(a));
}

fn checkInsert(comptime G: type, comptime F: type) !void {
    var fx: Fixture(G, F) = undefined;
    const rel = try fx.init();
    defer fx.deinit();

    const new: User = .{ .id = 7, .name = "gus", .age = null, .role = .b };
    try testing.expectEqualDeep(new, try rel.create(new).commit());
    var buf: [users.len + 4]User = undefined;
    try expectRows(rel, "after inserting id 7", seededPlus(&buf, &.{new}));

    const clash: User = .{ .id = 3, .name = "zed", .age = 1, .role = .a };
    try expectSharedError("insert an existing key", error.DuplicatePrimaryKey, rel.create(clash).commit());
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
    const returned = try rel.create(.{ .id = 7, .name = heap, .age = 40, .role = .c }).commit();
    @memset(heap, '?');

    errdefer std.debug.print("zom.lint:   case: a string inserted from an overwritten buffer\n", .{});
    try testing.expectEqualStrings("gus", returned.name);
    const stored = (try rel.byPk(7).one(a)) orelse return error.TestExpectedOneTuple;
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
    try testing.expectEqual(@as(?User, null), try rel.byPk(1).one(a));
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
