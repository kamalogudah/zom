//! Caller-owned strings (`strings = .caller`): a fake gateway over
//! `memory.Store` that copies every string it returns into the allocator it
//! is given, as zom-pg does. Run on `std.testing.allocator`, every test here
//! fails on a string the relation layer drops without freeing.

const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const Allocator = std.mem.Allocator;

/// `s` is what the dataset evaluates itself; the rest runs in memory on a
/// `.fallback` relation, which is where tuples get dropped.
fn OwnedGateway(comptime s: zom.Supports) type {
    return struct {
        const Gateway = @This();
        pub const adapter_name = "owned";
        pub const Config = struct {};

        allocator: Allocator,
        users: ?*Dataset(zom.lint.Users) = null,

        pub fn init(allocator: Allocator, _: Config) Gateway {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Gateway) void {
            if (self.users) |d| {
                d.store.deinit();
                self.allocator.destroy(d);
            }
        }

        pub fn Dataset(comptime S: type) type {
            return struct {
                const Self = @This();
                const T = S.Tuple;
                const Q = zom.Query(T);
                pub const supports = s;
                pub const strings: zom.StringOwnership = .caller;

                store: zom.memory.Store(S),

                pub fn read(self: *Self, query: Q, allocator: Allocator) ![]T {
                    const rows = try self.store.read(query, allocator);
                    return own(T, allocator, rows);
                }
                pub fn readProjected(self: *Self, query: Q, comptime P: type, allocator: Allocator) ![]P {
                    const rows = try self.store.readProjected(query, P, allocator);
                    return own(P, allocator, rows);
                }
                pub fn count(self: *Self, query: Q) !usize {
                    return self.store.count(query);
                }
                pub fn insert(self: *Self, row: T, allocator: Allocator) !T {
                    return zom.strings.dupeFields(T, allocator, try self.store.insert(row));
                }
                pub fn insertMany(self: *Self, rows: []const T) !usize {
                    return self.store.insertMany(rows);
                }
                pub fn update(self: *Self, query: Q, changes: []const Q.Change) !usize {
                    return self.store.update(query, changes);
                }
                pub fn delete(self: *Self, query: Q) !usize {
                    return self.store.delete(query);
                }

                /// Replaces each row's strings (still the store's) by copies.
                fn own(comptime R: type, allocator: Allocator, rows: []R) ![]R {
                    var done: usize = 0;
                    errdefer {
                        for (rows[0..done]) |r| zom.strings.freeFields(R, allocator, r, &.{});
                        allocator.free(rows);
                    }
                    while (done < rows.len) : (done += 1) rows[done] = try zom.strings.dupeFields(R, allocator, rows[done]);
                    return rows;
                }
            };
        }

        pub fn dataset(self: *Gateway, comptime S: type) !*Dataset(S) {
            if (S != zom.lint.Users) @compileError("this fake only holds zom.lint.Users");
            if (self.users) |d| return d;
            const d = try self.allocator.create(Dataset(S));
            d.* = .{ .store = .init(self.allocator) };
            self.users = d;
            return d;
        }
    };
}

fn Factory(comptime G: type) type {
    return struct {
        pub fn create(allocator: Allocator) !G {
            return G.init(allocator, .{});
        }
        pub fn destroy(g: *G) void {
            g.deinit();
        }
    };
}

/// Everything but joins: this fake holds `zom.lint.Users` only, and the
/// join check needs `zom.lint.Posts` and `zom.lint.Comments` too.
const Full = OwnedGateway(blk: {
    var s: zom.Supports = .all;
    s.join = false;
    break :blk s;
});
/// Default supports: no `in`, `like`, `or` or projection.
const Narrow = OwnedGateway(.{ .offset = false });

test "a caller-owned adapter passes zom.lint, with readProjected" {
    try testing.expectEqual(zom.StringOwnership.caller, zom.Adapter(Full).stringOwnership(zom.lint.Users));
    try zom.lint.run(Full, Factory(Full));
}

test "a caller-owned adapter passes zom.lint, with select mapped down by zom" {
    try zom.lint.run(Narrow, Factory(Narrow));
}

const seed = zom.lint.users;

fn fixture(comptime G: type, g: *G) !zom.Relation(zom.lint.Users, G) {
    g.* = G.init(testing.allocator, .{});
    errdefer g.deinit();
    const rel = try zom.Relation(zom.lint.Users, G).init(g);
    _ = try rel.createMany(&seed).commit();
    return rel;
}

test "fallback reads free the strings of the rows they filter out and page past" {
    var g: Narrow = undefined;
    const rel = (try fixture(Narrow, &g)).allowFallback();
    defer g.deinit();

    // `in` and `offset` run in memory: rows are filtered out, sorted, and
    // skipped before and after the page.
    const page = rel.where(.id, .in, .{ 1, 2, 3, 4, 5 }).order(.id, .asc).limit(2).offset(1);
    const rows = try page.toSlice(testing.allocator);
    defer page.free(testing.allocator, rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqualStrings("ada", rows[0].name);
    try testing.expectEqualStrings("fay", rows[1].name);

    try testing.expectEqual(@as(usize, 2), try page.count(testing.allocator));
    const named = try page.select(.{.name}).toSlice(testing.allocator);
    defer page.select(.{.name}).free(testing.allocator, named);
    try testing.expectEqualStrings("ada", named[0].name);
}

test "one frees every tuple it read when there is more than one" {
    var g: Full = undefined;
    const rel = try fixture(Full, &g);
    defer g.deinit();
    try testing.expectError(error.MoreThanOneTuple, rel.where(.role, .eq, .a).one(testing.allocator));
    const u = (try rel.byPk(6).one(testing.allocator)).?;
    defer rel.freeOne(testing.allocator, u);
    try testing.expectEqualStrings("cy", u.name);
}

test "mapTo moves the strings it copies to the entities and frees the rest" {
    var g: Full = undefined;
    const rel = try fixture(Full, &g);
    defer g.deinit();

    const Entity = struct { id: u32, label: []const u8 };
    const M = zom.Mapper(zom.lint.User, Entity, .{ .renames = &.{.{ .from = "name", .to = "label" }} });
    try testing.expectEqualDeep(@as([]const []const u8, &.{ "id", "name" }), M.sources);
    const out = try rel.order(.id, .asc).mapWith(M, testing.allocator);
    defer zom.strings.freeAll(Entity, testing.allocator, out);
    try testing.expectEqualStrings("dee", out[0].label);
}

test "commitAlloc works the same on a dataset-owned adapter" {
    var g = zom.memory.Gateway.init(testing.allocator, .{});
    defer g.deinit();
    const rel = try zom.Relation(zom.lint.Users, zom.memory.Gateway).init(&g);
    const stored = try rel.create(seed[0]).commitAlloc(testing.allocator);
    rel.freeOne(testing.allocator, stored); // a no-op here
    try testing.expectEqualStrings("bob", stored.name);
    const rows = try rel.toSlice(testing.allocator);
    rel.free(testing.allocator, rows);
}
