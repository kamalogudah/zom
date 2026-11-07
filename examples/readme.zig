//! The code blocks of README.md and docs/*.md, pasted verbatim into tests
//! so that `zig build test` fails when the docs drift from the API. Each
//! test names the section it comes from ("README: Join" is the "Join"
//! section, now in docs/associations.md); keep them in sync. The sections
//! live in: README.md (Quick start, A longer tour), docs/api.md
//! (Projections, Pagination, Query support, Value), docs/containers.md
//! (Container, Repository, Plugins, Writing a plugin, Instrumentation),
//! docs/associations.md (Associations, Combine, Join, Associated creates,
//! Nesting) and docs/adapters.md (The adapter contract, Checking an
//! adapter with zom.lint). The Postgres walkthrough's blocks come from
//! examples/pg_repo, and zom-sql's from adapters/sql/README.md (tested in
//! adapters/sql/src/compile_test.zig).

const std = @import("std");
const testing = std.testing;

test "README: Quick start, then A longer tour" {
    const allocator = testing.allocator;

    // -- README: Usage ----------------------------------------------------
    const zom = @import("zom");

    const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
    const Post = struct { id: u32, user_id: u32, title: []const u8 };
    const PostSchema = zom.Schema(Post, "posts", .id, .{});
    const UserSchema = zom.Schema(User, "users", .id, .{
        .associations = .{ .posts = zom.hasMany(PostSchema, .user_id) },
    });
    const Users = zom.Relation(UserSchema, zom.memory.Gateway);

    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);

    _ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();

    const active = try users.where(.deleted_at, .eq, null).order(.name, .asc).toSlice(allocator);
    defer allocator.free(active);

    // -- README: A longer tour --------------------------------------------
    const Author = struct { id: u32, full_name: []const u8, posts: []const Post = &.{} };
    const Posts = zom.Relation(PostSchema, zom.memory.Gateway);
    const AuthorMapper = zom.Mapper(User, Author, .{
        .renames = &.{.{ .from = "name", .to = "full_name" }},
    });

    const posts = try Posts.init(&gw);
    _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values" }).commit();

    // Updates and deletes target whatever the relation selects.
    const changed = try users.byPk(1).update().set(.age, 32).commit(); // 1
    const removed = try users.where(.age, .gt, 100).delete(); // 0

    // Tuples become entities, each with its posts attached: one query for
    // the users, one for their posts. One deinit frees the whole tree.
    var authors = try users.combine(.posts, posts).mapWith(AuthorMapper, allocator);
    defer authors.deinit();

    // -- checks (not in the README) ---------------------------------------
    try testing.expectEqual(1, active.len);
    try testing.expectEqual(1, changed);
    try testing.expectEqual(0, removed);
    try testing.expectEqualStrings("Achieng", authors.items[0].full_name);
    try testing.expectEqual(1, authors.items[0].posts.len);
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
    const id: zom.Value = .{ .uint128 = std.math.maxInt(u128) }; // a TigerBeetle id
    std.debug.assert(id.order(big).? == .gt);
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

    try app.transaction(.default, {}, struct {
        fn f(_: void, tx: App.Relations) !void {
            _ = try tx.users.create(.{ .id = 2, .name = "Otieno", .age = 24 }).commit();
            _ = try tx.users.byPk(1).update().set(.age, 32).commit();
        }
    }.f);

    try testing.expectEqual(2, try users.count());
}

test "README: Repository" {
    const allocator = testing.allocator;
    const zom = @import("zom");
    const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
    const Post = struct { id: u32, user_id: u32, title: []const u8 };

    const App = zom.Container(.{
        .gateways = .{ .default = zom.memory.Gateway },
        .relations = .{
            .users = .{ zom.Schema(User, "users", .id, .{}), .default },
            .posts = .{ zom.Schema(Post, "posts", .id, .{}), .default },
        },
    });
    var app: App = undefined;
    try app.init(allocator, .{});
    defer app.deinit();

    {
        const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users, .posts } });

        var repo = UserRepo.init(&app);
        _ = try repo.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();
        const u = try repo.byPk(1).one(allocator); // ?User
        const n = try repo.relations.posts.count();

        try testing.expectEqualStrings("Achieng", u.?.name);
        try testing.expectEqual(0, n);
    }
    {
        const Users = struct {
            rel: @FieldType(App.Relations, "users"),

            pub fn active(self: @This()) @TypeOf(self.rel) {
                return self.rel.where(.deleted_at, .eq, null);
            }
        };

        const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users, .posts = .plain } });

        var repo = UserRepo.init(&app);
        _ = try repo.create(.{ .id = 2, .name = "Wanjiru", .age = 42, .deleted_at = 1_700_000_000 }).commit();
        const active = try repo.relations.users.active().count();
        const older = try repo.root().active().where(.age, .gt, 30).count();

        try testing.expectEqual(1, active);
        try testing.expectEqual(1, older);

        try app.transaction(.default, {}, struct {
            fn f(_: void, tx: App.Relations) !void {
                const r = UserRepo.fromRelations(tx);
                _ = try r.create(.{ .id = 3, .name = "Otieno", .age = 24 }).commit();
            }
        }.f);
        try testing.expectEqual(3, try repo.all().count());
    }
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

test "README: Plugins" {
    const zom = @import("zom");
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();

    // -- README: Plugins --------------------------------------------------
    const Note = struct { id: u32, title: []const u8, created_at: i64 = 0, updated_at: i64 = 0 };
    const NoteSchema = zom.Schema(Note, "notes", .id, .{
        .plugins = .{zom.plugins.timestamps(.{ .created = .created_at, .updated = .updated_at })},
    });
    const Notes = zom.Relation(NoteSchema, zom.memory.Gateway);

    // The clock comes from the relation's plugin context, never from the
    // plugin itself: `.{ .io = io }` in an app, a fixed time in tests.
    const notes = (try Notes.init(&gw)).withPluginContext(.{ .clock = .{ .fixed = 1_700_000_000_000_000_000 } });

    const note = try notes.create(.{ .id = 1, .title = "Draft" }).commit();
    // note.created_at == note.updated_at == 1_700_000_000_000_000_000
    _ = try notes.byPk(1).update().set(.title, "Final").commit(); // sets updated_at too
    // ---------------------------------------------------------------------

    try testing.expectEqual(@as(i64, 1_700_000_000_000_000_000), note.created_at);
    try testing.expectEqual(note.created_at, note.updated_at);
}

test "README: Pagination" {
    const zom = @import("zom");
    const allocator = testing.allocator;
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const User = struct { id: u32 };
    const users = try zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway).init(&gw);
    for (1..46) |i| _ = try users.create(.{ .id = @intCast(i) }).commit();

    // -- README: Pagination -----------------------------------------------
    const p = try users.order(.id, .asc).page(2).perPage(20).paginate(allocator);
    defer p.free(allocator);
    // p.rows: rows 21 to 40 (fewer on the last page, none past it)
    // p.total: every row of `users`, p.pages: ceil(total / 20)
    // p.page == 2, p.per_page == 20
    // ---------------------------------------------------------------------

    try testing.expectEqual(20, p.rows.len);
    try testing.expectEqual(21, p.rows[0].id);
    try testing.expectEqual(45, p.total);
    try testing.expectEqual(3, p.pages);
}

test "README: Writing a plugin" {
    const zom = @import("zom");

    // -- README: Writing a plugin -----------------------------------------
    const Frozen = struct {
        /// When the schema is analysed: reject schemas the plugin can't handle.
        pub fn validate(comptime S: type) void {
            if (!@hasField(S.Tuple, "id")) @compileError("Frozen needs an id");
        }
        /// On the tuple about to be inserted (a copy).
        pub fn beforeCreate(comptime S: type, tuple: *S.Tuple, ctx: *const zom.plugins.Context) void {
            _ = .{ tuple, ctx };
        }
        /// On the changes about to be applied. May return an error union, whose
        /// errors are added to `commit`'s.
        pub fn beforeUpdate(comptime S: type, changes: *zom.plugins.ChangeList(S.Tuple), ctx: *const zom.plugins.Context) error{Frozen}!void {
            _ = ctx;
            if (changes.find(.id) != null) return error.Frozen;
        }
    };
    // ---------------------------------------------------------------------

    const Item = struct { id: u32, name: []const u8 };
    const Items = zom.Relation(zom.Schema(Item, "items", .id, .{ .plugins = .{Frozen} }), zom.memory.Gateway);
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const items = try Items.init(&gw);
    _ = try items.create(.{ .id = 1, .name = "a" }).commit();
    try testing.expectError(error.Frozen, items.byPk(1).update().set(.id, 2).commit());
}

test "README: Associations" {
    const posts = assoc.UserSchema.association(.posts);
    try testing.expect(posts.kind == .has_many);
    try testing.expect(posts.target == assoc.PostSchema);
    try testing.expectEqualStrings("user_id", posts.foreign_key);
    try testing.expectEqualStrings("id", posts.primary_key);
    try testing.expect(assoc.UserSchema.associations.posts.target == assoc.PostSchema);
    try testing.expect(assoc.PostSchema.association(.author).target == assoc.UserSchema);
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

test "README: Nesting" {
    const zom = @import("zom");
    const allocator = testing.allocator;
    const User = struct { id: u32, name: []const u8 };
    const Post = struct { id: u32, user_id: u32, title: []const u8 };
    const CommentRow = struct { id: u32, post_id: u32, body: []const u8 };
    const S = struct {
        const Users = zom.Schema(User, "users", .id, .{ .associations = struct {
            pub const posts = zom.hasMany(Posts, .user_id);
        } });
        const Posts = zom.Schema(Post, "posts", .id, .{ .associations = struct {
            pub const comments = zom.hasMany(Comments, .post_id);
        } });
        const Comments = zom.Schema(CommentRow, "comments", .id, .{});
    };
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();
    const users = try zom.Relation(S.Users, zom.memory.Gateway).init(&gw);
    const posts = try zom.Relation(S.Posts, zom.memory.Gateway).init(&gw);
    const comments = try zom.Relation(S.Comments, zom.memory.Gateway).init(&gw);
    _ = try users.create(.{ .id = 1, .name = "Achieng" }).commit();
    _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "a" }).commit();
    _ = try comments.create(.{ .id = 100, .post_id = 10, .body = "Asante" }).commit();

    // -- README: Nesting ----------------------------------------------------
    const Comment = struct { id: u32, body: []const u8 };
    const PostWithComments = struct { id: u32, title: []const u8, comments: []const Comment };
    const Author = struct { id: u32, name: []const u8, posts: []const PostWithComments };

    var result = try users.order(.id, .asc)
        .combine(.posts, posts.order(.id, .asc).combine(.comments, comments.order(.id, .asc)))
        .mapTo(Author, allocator);
    defer result.deinit(); // frees every level
    // ---------------------------------------------------------------------

    try testing.expectEqualStrings("Asante", result.items[0].posts[0].comments[0].body);
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

test "README: Instrumentation" {
    const zom = @import("zom");
    const allocator = testing.allocator;
    var gw = zom.memory.Gateway.init(allocator, .{});
    defer gw.deinit();

    // -- README: Instrumentation ------------------------------------------
    const Event = zom.plugins.instrumentation.Event;
    const Outcome = zom.plugins.instrumentation.Outcome;

    // Counts the rows each read returns.
    const RowCounter = struct {
        var rows_read: usize = 0;
        pub fn before(_: Event) void {}
        pub fn after(e: Event, o: Outcome) void {
            if (e.op == .read) rows_read += o.rows orelse 0;
        }
    };

    const Note = struct { id: u32, title: []const u8 };
    const NoteSchema = zom.Schema(Note, "notes", .id, .{
        // Logs each call to `std.log.scoped(.zom)`: successes at .debug,
        // errors at .warn.
        .plugins = .{ zom.plugins.instrumentation.log(std.log.scoped(.zom)), RowCounter },
    });
    const notes = try zom.Relation(NoteSchema, zom.memory.Gateway).init(&gw);

    _ = try notes.create(.{ .id = 1, .title = "Draft" }).commit(); // .insert, 1 row
    const all = try notes.toSlice(allocator); // .read, 1 row
    defer notes.free(allocator, all);
    // RowCounter.rows_read == 1
    // ---------------------------------------------------------------------

    try testing.expectEqual(1, RowCounter.rows_read);
}
