const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const UserTuple = fixtures.UserTuple;
const Users = fixtures.Users;
const Posts = fixtures.Posts;
const seed = fixtures.seed;

fn fieldNames(comptime T: type) []const []const u8 {
    const fields = @typeInfo(T).@"struct".field_names;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f;
    const final = names;
    return &final;
}

fn expectFieldNames(comptime T: type, comptime want: []const []const u8) !void {
    const got = comptime fieldNames(T);
    try testing.expectEqual(want.len, got.len);
    inline for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "select reads a struct with exactly the selected fields" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const rows = try users.select(.{ .id, .name }).order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);

    const Row = @typeInfo(@TypeOf(rows)).pointer.child;
    const types = @typeInfo(Row).@"struct".field_types;
    try testing.expectEqual(2, types.len);
    try expectFieldNames(Row, &.{ "id", "name" });
    try testing.expectEqual(u32, types[0]);
    try testing.expectEqual([]const u8, types[1]);

    try testing.expectEqual(3, rows.len);
    try testing.expectEqual(1, rows[0].id);
    try testing.expectEqualStrings("Achieng", rows[0].name);
    try testing.expectEqualStrings("Wanjiru", rows[2].name);
}

test "Project keeps the given order, the types and the defaults" {
    const P = zom.Project(UserTuple, .{ .role, .deleted_at, .id });
    try expectFieldNames(P, &.{ "role", "deleted_at", "id" });
    const info = @typeInfo(P).@"struct";
    try testing.expectEqual(fixtures.Role.member, info.field_attrs[0].defaultValue(info.field_types[0]).?);
    try testing.expectEqual(@as(?i64, null), info.field_attrs[1].defaultValue(info.field_types[1]).?);
    try testing.expectEqual(@as(?u32, null), info.field_attrs[2].defaultValue(info.field_types[2]));

    const p: P = .{ .id = 7 };
    try testing.expectEqual(fixtures.Role.member, p.role);
    try testing.expectEqual(@as(?i64, null), p.deleted_at);
}

test "equal selections give the same type" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    const a = users.select(.{ .id, .name });
    const b = users.where(.age, .gt, 3).select(.{ .id, .name });
    try testing.expect(@TypeOf(a) == @TypeOf(b));
    try testing.expect(@TypeOf(a).Output == zom.Project(UserTuple, .{ .id, .name }));
    try testing.expect(@TypeOf(a) == zom.RelationOf(Users.schema, zom.memory.Gateway, zom.Project(UserTuple, .{ .id, .name })));

    // Narrowing a selection lands on the same type as selecting directly.
    const c = users.select(.{ .id, .name, .email }).select(.{ .id, .name });
    try testing.expect(@TypeOf(a) == @TypeOf(c));

    // Order is part of the type.
    try testing.expect(@TypeOf(a) != @TypeOf(users.select(.{ .name, .id })));

    // An unprojected relation is `Relation`, reading whole tuples.
    try testing.expect(Users == zom.RelationOf(Users.schema, zom.memory.Gateway, UserTuple));
    try testing.expect(Users.Output == UserTuple);
    try testing.expect(!Users.projected and @TypeOf(a).projected);
}

test "filters and orders may use attributes that were not selected" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    // Before select.
    const names = users.where(.age, .gt, 25).order(.age, .desc).select(.{.name});
    try testing.expectEqual(2, try names.count());
    const rows = try names.toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(2, rows.len);
    try testing.expectEqualStrings("Wanjiru", rows[0].name);
    try testing.expectEqualStrings("Achieng", rows[1].name);

    // After select, with paging.
    const ids = users.select(.{.id}).where(.deleted_at, .is_null, {}).order(.email, .desc).limit(1);
    const one = try ids.toSlice(testing.allocator);
    defer testing.allocator.free(one);
    try testing.expectEqual(1, one.len);
    try testing.expectEqual(2, one[0].id);

    const admins = users.select(.{.email}).whereAny(.{ .{ .role, .eq, .admin }, .{ .age, .lt, 25 } }).order(.id, .asc).offset(1);
    const rest = try admins.toSlice(testing.allocator);
    defer testing.allocator.free(rest);
    try testing.expectEqual(1, rest.len);
    try testing.expectEqualStrings("otieno@example.com", rest[0].email);
}

test "one, first, byPk and mapTo on a projection" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const names = users.select(.{ .id, .name });
    const otieno = (try names.byPk(2).one(testing.allocator)).?;
    try testing.expectEqualStrings("Otieno", otieno.name);
    try testing.expectEqual(null, try names.byPk(99).first(testing.allocator));
    try testing.expectError(error.MoreThanOneTuple, names.one(testing.allocator));

    const Name = struct { name: []const u8, nickname: []const u8 = "-" };
    const mapped = try names.order(.id, .desc).mapTo(Name, testing.allocator);
    defer testing.allocator.free(mapped);
    try testing.expectEqualStrings("Wanjiru", mapped[0].name);
    try testing.expectEqualStrings("-", mapped[0].nickname);
}

test "the primary key does not have to be selected" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const rows = try users.byPk(3).select(.{.age}).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try expectFieldNames(@typeInfo(@TypeOf(rows)).pointer.child, &.{"age"});
    try testing.expectEqual(42, rows[0].age);
}

test "update and delete go through a projected relation's query" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    try seed(users, try Posts.init(&gw));

    const names = users.select(.{.name});
    try testing.expectEqual(1, try names.byPk(2).update().set(.email, "o@example.com").commit());
    try testing.expectEqualStrings("o@example.com", (try users.byPk(2).one(testing.allocator)).?.email);
    try testing.expectEqual(1, try names.where(.age, .gt, 40).delete());
    try testing.expectEqual(2, try users.count());
}

// -- adapters with and without readProjected --------------------------------

/// A gateway whose datasets wrap a `zom.memory.Store`. With `projection`
/// they declare `readProjected` and count the calls; without it they have
/// only `read` and `count`, so `select` falls back to mapping whole rows.
fn WrapGateway(comptime projection: bool) type {
    return struct {
        const Self = @This();

        pub const adapter_name = if (projection) "projecting" else "plain";
        pub const Config = struct {};

        inner: zom.memory.Gateway,

        pub fn init(a: std.mem.Allocator, _: Config) Self {
            return .{ .inner = .init(a, .{}) };
        }
        pub fn deinit(self: *Self) void {
            self.inner.deinit();
        }

        pub fn Dataset(comptime S: type) type {
            return if (projection) ProjectingDataset(S) else PlainDataset(S);
        }

        pub fn dataset(self: *Self, comptime S: type) !*Dataset(S) {
            const static = struct {
                var instance: Dataset(S) = undefined;
            };
            static.instance = .{ .store = try self.inner.dataset(S) };
            return &static.instance;
        }
    };
}

fn PlainDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        store: *zom.memory.Store(S),

        pub fn read(self: *@This(), query: Q, a: std.mem.Allocator) ![]T {
            return self.store.read(query, a);
        }
        pub fn count(self: *@This(), query: Q) !usize {
            return self.store.count(query);
        }
        pub fn insert(self: *@This(), t: T) !T {
            return self.store.insert(t);
        }
    };
}

var projected_reads: usize = 0;

fn ProjectingDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        pub const supports: zom.Supports = .{ .projection = true };

        store: *zom.memory.Store(S),

        pub fn read(self: *@This(), query: Q, a: std.mem.Allocator) ![]T {
            return self.store.read(query, a);
        }
        pub fn readProjected(self: *@This(), query: Q, comptime P: type, a: std.mem.Allocator) ![]P {
            projected_reads += 1;
            return self.store.readProjected(query, P, a);
        }
        pub fn count(self: *@This(), query: Q) !usize {
            return self.store.count(query);
        }
        pub fn insert(self: *@This(), t: T) !T {
            return self.store.insert(t);
        }
    };
}

fn expectSameRows(comptime G: type) !void {
    var gw = G.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(Users.schema, G).init(&gw);
    _ = try users.create(.{ .id = 1, .name = "Achieng", .email = "a@example.com", .age = 31, .role = .admin }).commit();
    _ = try users.create(.{ .id = 2, .name = "Otieno", .email = "o@example.com", .age = 24 }).commit();
    _ = try users.create(.{ .id = 3, .name = "Wanjiru", .email = "w@example.com", .age = 42 }).commit();

    const rows = try users.where(.age, .gt, 25).order(.age, .desc).select(.{ .name, .role }).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try expectFieldNames(@typeInfo(@TypeOf(rows)).pointer.child, &.{ "name", "role" });
    try testing.expectEqual(2, rows.len);
    try testing.expectEqualStrings("Wanjiru", rows[0].name);
    try testing.expectEqual(fixtures.Role.member, rows[0].role);
    try testing.expectEqualStrings("Achieng", rows[1].name);
    try testing.expectEqual(fixtures.Role.admin, rows[1].role);
}

test "a dataset without projection support reads whole rows and maps them down" {
    try testing.expect(!zom.Adapter(WrapGateway(false)).supports(Users.schema).projection);
    try expectSameRows(WrapGateway(false));
}

test "a dataset with projection support reads through readProjected" {
    const before = projected_reads;
    try expectSameRows(WrapGateway(true));
    try testing.expectEqual(before + 1, projected_reads);

    // Without `select`, `read` is used as before.
    var gw = WrapGateway(true).init(testing.allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(Users.schema, WrapGateway(true)).init(&gw);
    const rows = try users.toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(before + 1, projected_reads);
}

test "file datasets forward readProjected" {
    const D = zom.file.FileDataset(Users.schema, struct {}, .read_only);
    try testing.expect(@hasDecl(D, "readProjected"));
}
