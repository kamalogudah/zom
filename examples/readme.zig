//! Every code block in README.md, pasted verbatim into a test so that
//! `zig build test` fails when the README drifts from the API. Each test
//! names the README section it comes from; keep them in sync.

const std = @import("std");
const testing = std.testing;

test "README: Usage, then A longer tour" {
    const allocator = testing.allocator;

    // -- README: Usage ----------------------------------------------------
    const zom = @import("zom");

    const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
    const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    _ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();

    const active = try users.where(.deleted_at, .eq, null).order(.name, .asc).toSlice(allocator);
    defer allocator.free(active);

    // -- README: A longer tour --------------------------------------------
    const Post = struct { id: u32, user_id: u32, title: []const u8 };
    const Author = struct { id: u32, full_name: []const u8, posts: []const Post = &.{} };
    const Posts = zom.Relation(zom.Schema(Post, "posts", .id), zom.memory.Gateway);
    const AuthorMapper = zom.Mapper(User, Author, .{
        .renames = &.{.{ .from = "name", .to = "full_name" }},
    });

    const posts = try Posts.init(&gw);
    _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values" }).commit();

    // Updates and deletes target whatever the relation selects.
    const changed = try users.byPk(1).update().set(.age, 32).commit(); // 1
    const removed = try users.where(.age, .gt, 100).delete(); // 0

    // Tuples become entities, then children are attached. combineMany
    // allocates one slice per parent, so give it an arena.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const authors = try users.mapWith(AuthorMapper, arena.allocator());
    try zom.combineMany(
        .{ .into = "posts", .parent_key = "id", .child_key = "user_id" },
        arena.allocator(),
        authors,
        try posts.toSlice(arena.allocator()),
    );

    // The same relation compiles to SQL instead.
    const compiled = try zom.sql.compileSelect(User, allocator, "users", users.where(.age, .gte, 18).query);
    defer compiled.deinit(allocator);
    // compiled.sql: SELECT "id", "name", "age", "deleted_at" FROM "users" WHERE "age" >= $1

    // -- checks (not in the README) ---------------------------------------
    try testing.expectEqual(1, active.len);
    try testing.expectEqual(1, changed);
    try testing.expectEqual(0, removed);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
    try testing.expectEqual(1, authors[0].posts.len);
    try testing.expectEqualStrings(
        "SELECT \"id\", \"name\", \"age\", \"deleted_at\" FROM \"users\" WHERE \"age\" >= $1",
        compiled.sql,
    );
}

test "README: Projections" {
    const allocator = testing.allocator;
    const zom = @import("zom");

    const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
    const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    _ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();

    // -- README: Projections ----------------------------------------------
    const names = try users.where(.age, .gt, 18).order(.age, .desc).select(.{ .id, .name }).toSlice(allocator);
    defer allocator.free(names);
    // @TypeOf(names[0]) has exactly `id` and `name`; `names[0].age` does not compile.

    // ---------------------------------------------------------------------
    try testing.expectEqual(2, @typeInfo(@TypeOf(names[0])).@"struct".fields.len);
    try testing.expectEqualStrings("Achieng", names[0].name);
}

test "README: Query support" {
    const allocator = testing.allocator;
    const zom = @import("zom");

    const User = struct { id: u32, name: []const u8, age: u8 };
    const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    _ = try users.create(.{ .id = 1, .name = "Achieng", .age = 24 }).commit();

    // -- README: Query support --------------------------------------------
    const young = try users.allowFallback().where(.age, .lt, 30).limit(10).toSlice(allocator);
    defer allocator.free(young);

    // ---------------------------------------------------------------------
    try testing.expectEqual(1, young.len);
}

test "README: Value" {
    const zom = @import("zom");

    // -- README: Value ----------------------------------------------------
    const big: zom.Value = .{ .uint = std.math.maxInt(u64) };
    std.debug.assert(big.order(.{ .int = -1 }).? == .gt);
    std.debug.assert(big.order(.{ .string = "x" }) == null); // different kinds never compare
    std.debug.assert(zom.query.toValue(@as(u64, 7)).eql(.{ .int = 7 }));
}

test "README: The adapter contract" {
    const zom = @import("zom");

    // -- README: The adapter contract -------------------------------------
    // The smallest gateway zom accepts: every dataset is empty, and with no
    // insert, update or delete it is read-only.
    const EmptyGateway = struct {
        pub const adapter_name = "empty";
        pub const Config = struct {};

        pub fn init(_: std.mem.Allocator, _: Config) @This() {
            return .{};
        }
        pub fn deinit(_: *@This()) void {}

        pub fn Dataset(comptime S: type) type {
            return struct {
                const Q = zom.Query(S.Tuple);

                pub fn read(_: *@This(), _: Q, allocator: std.mem.Allocator) ![]S.Tuple {
                    return allocator.alloc(S.Tuple, 0);
                }
                pub fn count(_: *@This(), _: Q) !usize {
                    return 0;
                }
            };
        }

        pub fn dataset(_: *@This(), comptime S: type) !*Dataset(S) {
            const static = struct {
                var instance: Dataset(S) = .{};
            };
            return &static.instance;
        }
    };

    // -- checks (not in the README) ---------------------------------------
    const Item = struct { id: u32 };
    const Items = zom.Relation(zom.Schema(Item, "items", .id), EmptyGateway);
    var gw = EmptyGateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try Items.init(&gw);
    try testing.expectEqual(0, try items.count());
    try testing.expectEqual(null, try items.one(testing.allocator));
    try testing.expectEqual(zom.Capabilities{}, comptime zom.Adapter(EmptyGateway).capabilities(Items.schema));
}

// -- README: Checking an adapter with zom.lint ------------------------------
// In a namespace, since the README's top-level `zom` would shadow the
// local `zom` constants in the tests above.
const lint_example = struct {
    const zom = @import("zom");

    const Factory = struct {
        pub fn create(allocator: std.mem.Allocator) !zom.memory.Gateway {
            return zom.memory.Gateway.init(allocator, .{});
        }
        pub fn destroy(g: *zom.memory.Gateway) void {
            g.deinit();
        }
        // Only needed when the dataset has neither `insert` nor `insertMany`:
        // pub fn seed(g: *G, comptime S: type, rows: []const S.Tuple) !void
    };

    test "zom.lint" {
        try zom.lint.run(zom.memory.Gateway, Factory);
    }
};

test {
    _ = lint_example;
}

test "README: Container" {
    const allocator = testing.allocator;
    const zom = @import("zom");
    const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
    const Post = struct { id: u32, user_id: u32, title: []const u8 };

    const UserSchema = zom.Schema(User, "users", .id);
    const PostSchema = zom.Schema(Post, "posts", .id);

    const App = zom.Container(.{
        .gateways = .{ .default = zom.memory.Gateway, .archive = zom.memory.Gateway },
        .relations = .{ .users = .{ UserSchema, .default }, .posts = .{ PostSchema, .archive } },
    });

    var app: App = undefined;
    try app.init(allocator, .{});
    defer app.deinit();

    const users = app.relations.users;
    _ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();

    try testing.expectEqual(1, try users.count());
    try testing.expectEqual(0, try app.relations.posts.count());
}
