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
    const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    _ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();

    const active = try users.where(.deleted_at, .eq, null).order(.name, .asc).toSlice(allocator);
    defer allocator.free(active);

    // -- README: A longer tour --------------------------------------------
    const Post = struct { id: u32, user_id: u32, title: []const u8 };
    const Author = struct { id: u32, full_name: []const u8, posts: []const Post = &.{} };
    const Posts = zom.Relation(zom.Schema(Post, "posts", .id, .{}), zom.memory.Gateway);
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

    // -- checks (not in the README) ---------------------------------------
    try testing.expectEqual(1, active.len);
    try testing.expectEqual(1, changed);
    try testing.expectEqual(0, removed);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
    try testing.expectEqual(1, authors[0].posts.len);
}

test "README: Projections" {
    const allocator = testing.allocator;
    const zom = @import("zom");

    const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
    const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

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
    const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

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
    const Items = zom.Relation(zom.Schema(Item, "items", .id, .{}), EmptyGateway);
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

    const UserSchema = zom.Schema(User, "users", .id, .{});
    const PostSchema = zom.Schema(Post, "posts", .id, .{});

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

// Container-level, as in the README: schemas that name each other must be
// container declarations, which Zig resolves lazily. Locals in a test body
// can't refer forward.
const assoc = struct {
    const zom = @import("zom");
    const User = struct { id: u32, name: []const u8 };
    const Post = struct { id: u32, user_id: u32, title: []const u8 };
    const Author = struct { id: u32, name: []const u8, posts: []const Post = &.{} };
    const Byline = struct { title: []const u8, author: ?User };

    const UserSchema = zom.Schema(User, "users", .id, .{
        .associations = struct {
            pub const posts = zom.hasMany(PostSchema, .user_id);
        },
    });
    const PostSchema = zom.Schema(Post, "posts", .id, .{
        .associations = struct {
            pub const author = zom.belongsTo(UserSchema, .user_id);
        },
    });
};

test "README: Associations" {
    const zom = assoc.zom;
    const posts = assoc.UserSchema.association(.posts);
    try testing.expect(posts.kind == .has_many);
    try testing.expect(posts.target == assoc.PostSchema);
    try testing.expectEqualStrings("user_id", posts.foreign_key);
    try testing.expectEqualStrings("id", posts.primary_key);
    try testing.expect(assoc.UserSchema.associations.posts.target == assoc.PostSchema);
    try testing.expect(assoc.PostSchema.association(.author).target == assoc.UserSchema);

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var authors_buf = [_]assoc.Author{ .{ .id = 1, .name = "Achieng" }, .{ .id = 2, .name = "Baraka" } };
    const authors: []assoc.Author = &authors_buf;
    const rows: []const assoc.Post = &.{ .{ .id = 10, .user_id = 2, .title = "b" }, .{ .id = 11, .user_id = 1, .title = "a" } };
    try zom.combineMany(
        .{ .into = "posts", .parent_key = posts.primary_key, .child_key = posts.foreign_key },
        arena.allocator(),
        authors,
        rows,
    );
    try testing.expectEqual(1, authors[0].posts.len);
    try testing.expectEqual(11, authors[0].posts[0].id);
    try testing.expectEqual(10, authors[1].posts[0].id);
}

test "README: Combine" {
    const zom = assoc.zom;
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(assoc.UserSchema, zom.memory.Gateway).init(&gw);
    const posts = try zom.Relation(assoc.PostSchema, zom.memory.Gateway).init(&gw);
    _ = try users.create(.{ .id = 1, .name = "Achieng" }).commit();
    _ = try users.create(.{ .id = 2, .name = "Baraka" }).commit();
    _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "a" }).commit();
    _ = try posts.create(.{ .id = 11, .user_id = 1, .title = "b" }).commit();

    var result = try users.order(.id, .asc).combine(.posts, posts.order(.id, .asc)).mapTo(assoc.Author, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(2, result.items[0].posts.len);
    try testing.expectEqual(0, result.items[1].posts.len);

    var bylines = try posts.combine(.author, users).mapTo(assoc.Byline, testing.allocator);
    defer bylines.deinit();
    try testing.expectEqualStrings("Achieng", bylines.items[0].author.?.name);
}

test "README: Associated creates" {
    const zom = assoc.zom;
    const allocator = testing.allocator;
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(assoc.UserSchema, zom.memory.Gateway).init(&gw);
    const posts = try zom.Relation(assoc.PostSchema, zom.memory.Gateway).init(&gw);
    _ = try users.create(.{ .id = 1, .name = "Achieng" }).commit();

    const author = (try users.byPk(1).one(allocator)).?;
    _ = try posts.associate(.author, author)
        .create(.{ .id = 12, .title = "Changesets" })
        .commit();

    // ROM's order, with the key given a value first.
    _ = try posts.create(.{ .id = 13, .user_id = undefined, .title = "Late" }).associate(.author, author).commit();
    const tuples = [_]assoc.Post{.{ .id = 14, .user_id = undefined, .title = "Batch" }};
    _ = try posts.createMany(&tuples).associate(.author, author).commitAlloc(allocator);

    // -- checks (not in the README) ---------------------------------------
    const scoped = posts.associate(.author, author);
    const rows = [_]@TypeOf(scoped).Input{.{ .id = 15, .title = "Scoped batch" }};
    try testing.expectEqual(1, try scoped.createMany(&rows).commitAlloc(allocator));
    var result = try users.combine(.posts, posts.order(.id, .asc)).mapTo(assoc.Author, allocator);
    defer result.deinit();
    try testing.expectEqual(4, result.items[0].posts.len);
}

test "README: Join" {
    const zom = @import("zom");
    const allocator = testing.allocator;
    const User = struct { id: u32, name: []const u8, role: enum { admin, member } = .member };
    const Post = struct { id: u32, user_id: ?u32, title: []const u8, published: bool };
    const S = struct {
        const UserSchema = zom.Schema(User, "users", .id, .{
            .associations = struct {
                pub const posts = zom.hasMany(PostSchema, .user_id);
            },
        });
        const PostSchema = zom.Schema(Post, "posts", .id, .{
            .associations = struct {
                pub const author = zom.belongsTo(UserSchema, .user_id);
            },
        });
    };
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(S.UserSchema, zom.memory.Gateway).init(&gw);
    const posts = try zom.Relation(S.PostSchema, zom.memory.Gateway).init(&gw);
    _ = try users.create(.{ .id = 1, .name = "Baraka", .role = .admin }).commit();
    _ = try users.create(.{ .id = 2, .name = "Achieng" }).commit();
    _ = try users.create(.{ .id = 3, .name = "Otieno" }).commit();
    _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "a", .published = true }).commit();
    _ = try posts.create(.{ .id = 11, .user_id = 1, .title = "b", .published = true }).commit();
    _ = try posts.create(.{ .id = 12, .user_id = 2, .title = "c", .published = false }).commit();

    // The users with at least one published post, each once.
    const authors = try users.join(.posts)
        .whereJoined(.posts, .published, .eq, true)
        .order(.name, .asc)
        .toSlice(allocator);
    defer users.free(allocator, authors);

    // -- checks (not in the README) ---------------------------------------
    try testing.expectEqual(1, authors.len);
    try testing.expectEqualStrings("Baraka", authors[0].name);
    try testing.expectEqual(2, try users.join(.posts).count());
    const by_admins = try posts.join(.author).whereJoined(.author, .role, .eq, .admin).toSlice(allocator);
    defer posts.free(allocator, by_admins);
    try testing.expectEqual(2, by_admins.len);
}
