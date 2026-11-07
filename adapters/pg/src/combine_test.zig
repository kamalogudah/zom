//! `combine` on zom-pg: the scenarios of src/tests/combine_test.zig (has
//! many, belongs to, empty groups, orphans, more keys than `max_in`,
//! nested levels) against Postgres, plus what only a caller-owned adapter
//! can get wrong: every string zom-pg copies out, through `read`,
//! `readProjected` or a `.fallback` read that filters in memory, must live
//! in the result's arena, so `testing.allocator` sees no leak after
//! `result.deinit()`, also when an allocation fails partway.
//!
//! The datasets are reached through `Probe`, a gateway over zom-pg that
//! counts each dataset's reads and the bind parameters of each statement
//! (compiled with zom-sql, as zom-pg does), and can leave features out of
//! `supports` to force the in-memory part of a `.fallback` read.
//!
//! Skipped unless `ZOM_PG_URL` is set (see lint_test.zig). Drops and
//! recreates the `pc_users`, `pc_posts` and `pc_comments` tables.

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("root.zig");
const zom_sql = @import("zom_sql");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
    age: ?u8,
    deleted_at: ?i64,
};
const Post = struct { id: u32, user_id: u32, title: []const u8, published: bool };
const Comment = struct { id: u32, post_id: u32, body: []const u8 };

const Users = zom.Schema(User, "pc_users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(Posts, .user_id);
    },
});
const Posts = zom.Schema(Post, "pc_posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(Users, .user_id);
        pub const comments = zom.hasMany(Comments, .post_id);
    },
});
const Comments = zom.Schema(Comment, "pc_comments", .id, .{});

// No foreign keys: the orphans (a post by user 9, a comment on post 99)
// are part of the scenarios.
const ddl = [_][]const u8{
    \\CREATE TABLE pc_users (
    \\  id bigint PRIMARY KEY,
    \\  name text NOT NULL,
    \\  email text NOT NULL,
    \\  age smallint,
    \\  deleted_at bigint
    \\)
    ,
    \\CREATE TABLE pc_posts (
    \\  id bigint PRIMARY KEY,
    \\  user_id bigint NOT NULL,
    \\  title text NOT NULL,
    \\  published boolean NOT NULL
    \\)
    ,
    \\CREATE TABLE pc_comments (
    \\  id bigint PRIMARY KEY,
    \\  post_id bigint NOT NULL,
    \\  body text NOT NULL
    \\)
    ,
};
const drops = [_][]const u8{
    "DROP TABLE IF EXISTS pc_comments",
    "DROP TABLE IF EXISTS pc_posts",
    "DROP TABLE IF EXISTS pc_users",
};

// -- the probe -----------------------------------------------------------------

/// zom-pg with each dataset's reads counted, and `supports` narrowed to `s`
/// (a subset of zom-pg's) so `.fallback` relations evaluate the rest in
/// memory, on strings zom-pg allocated.
fn Probe(comptime s: zom.Supports) type {
    return struct {
        const Gw = @This();
        pub const adapter_name = "postgres_probe";
        pub const Config = struct {};

        inner: *zom_pg.Gateway,

        pub fn init(_: Allocator, _: Config) !Gw {
            return error.OpenTheInnerGatewayInstead;
        }
        pub fn deinit(_: *Gw) void {}

        pub fn Dataset(comptime S: type) type {
            return struct {
                const Self = @This();
                const T = S.Tuple;
                const Q = zom.Query(T);

                pub const supports: zom.Supports = s;
                pub const strings: zom.StringOwnership = .caller;

                /// Reads since the last `reset`, and how many of them went
                /// through `readProjected`.
                pub var reads: usize = 0;
                pub var projected_reads: usize = 0;
                /// The most bind parameters one read's statement had.
                pub var max_params: usize = 0;

                inner: *zom_pg.Gateway.Dataset(S),

                pub fn reset() void {
                    reads = 0;
                    projected_reads = 0;
                    max_params = 0;
                }

                pub fn read(self: *Self, query: Q, allocator: Allocator) ![]T {
                    try note(query);
                    return self.inner.read(query, allocator);
                }
                pub fn readProjected(self: *Self, query: Q, comptime P: type, allocator: Allocator) ![]P {
                    try note(query);
                    projected_reads += 1;
                    return self.inner.readProjected(query, P, allocator);
                }
                pub fn count(self: *Self, query: Q) !usize {
                    return self.inner.count(query);
                }
                pub fn insert(self: *Self, row: T, allocator: Allocator) !T {
                    return self.inner.insert(row, allocator);
                }
                pub fn insertMany(self: *Self, rows: []const T) !usize {
                    return self.inner.insertMany(rows);
                }

                fn note(query: Q) !void {
                    reads += 1;
                    // The statement zom-pg prepares for this query. The
                    // probe's own scratch, so it never fails the allocator
                    // under test.
                    const compiled = zom_sql.compileSelect(.postgres, T, std.heap.page_allocator, S.name, query) catch |err| switch (err) {
                        error.InvalidNullComparison => return,
                        else => |e| return e,
                    };
                    defer compiled.deinit(std.heap.page_allocator);
                    max_params = @max(max_params, compiled.params.len);
                }
            };
        }

        pub fn dataset(self: *Gw, comptime S: type) !*Dataset(S) {
            const static = struct {
                var instance: Dataset(S) = undefined;
            };
            static.instance = .{ .inner = try self.inner.dataset(S) };
            return &static.instance;
        }
    };
}

/// Everything zom-pg evaluates.
const Full = Probe(.all);
/// No pattern matching: `like` filters run in memory.
const NoLike = Probe(blk: {
    var x: zom.Supports = .all;
    x.like = false;
    break :blk x;
});
/// No `in` either: combine's batched `whereIn` runs in memory too, so each
/// batch reads the target's other filters' rows and drops the rest.
const NoIn = Probe(blk: {
    var x: zom.Supports = .all;
    x.like = false;
    x.in = false;
    break :blk x;
});

// -- fixture ---------------------------------------------------------------------

/// A Postgres gateway with the three tables empty, or null without
/// `ZOM_PG_URL`.
const Db = struct {
    url: []const u8,
    gw: zom_pg.Gateway,

    fn open(self: *Db) !void {
        self.url = testing.environ.getAlloc(testing.allocator, "ZOM_PG_URL") catch |err| switch (err) {
            error.EnvironmentVariableMissing => return error.SkipZigTest,
            else => |e| return e,
        };
        errdefer testing.allocator.free(self.url);
        self.gw = try zom_pg.Gateway.init(testing.allocator, .{ .io = testing.io, .url = self.url, .pool_size = 2 });
        errdefer self.gw.deinit();
        for (drops) |sql| try self.gw.exec(sql);
        for (ddl) |sql| try self.gw.exec(sql);
    }

    fn close(self: *Db) void {
        for (drops) |sql| self.gw.exec(sql) catch {};
        self.gw.deinit();
        testing.allocator.free(self.url);
    }
};

fn Rels(comptime G: type) type {
    return struct {
        users: zom.Relation(Users, G),
        posts: zom.Relation(Posts, G),
        comments: zom.Relation(Comments, G),

        fn init(gw: *G) !@This() {
            return .{ .users = try .init(gw), .posts = try .init(gw), .comments = try .init(gw) };
        }

        fn reset() void {
            G.Dataset(Users).reset();
            G.Dataset(Posts).reset();
            G.Dataset(Comments).reset();
        }
    };
}

/// The rows of src/tests/combine_test.zig: user 3 is soft-deleted, and
/// post 14 belongs to a user who doesn't exist.
fn seed(comptime G: type, r: Rels(G)) !void {
    _ = try r.users.createMany(&[_]User{
        .{ .id = 1, .name = "Achieng", .email = "achieng@example.com", .age = 31, .deleted_at = null },
        .{ .id = 2, .name = "Otieno", .email = "otieno@example.com", .age = 24, .deleted_at = null },
        .{ .id = 3, .name = "Wanjiru", .email = "wanjiru@example.com", .age = 42, .deleted_at = 1_700_000_000 },
    }).commit();
    _ = try r.posts.createMany(&[_]Post{
        .{ .id = 10, .user_id = 1, .title = "Relations are values", .published = true },
        .{ .id = 11, .user_id = 1, .title = "Mappers, not models", .published = false },
        .{ .id = 12, .user_id = 2, .title = "Comptime schemas", .published = true },
        .{ .id = 13, .user_id = 3, .title = "Soft deletes", .published = true },
        .{ .id = 14, .user_id = 9, .title = "Orphan", .published = true },
    }).commit();
    _ = try r.comments.createMany(&[_]Comment{
        .{ .id = 100, .post_id = 10, .body = "Asante" },
        .{ .id = 101, .post_id = 10, .body = "Nzuri sana" },
        .{ .id = 102, .post_id = 12, .body = "Comptime!" },
        .{ .id = 103, .post_id = 99, .body = "Orphan comment" },
    }).commit();
}

/// `n` users; every other one (from the first) has two posts, each with
/// one comment whose id is the post's.
fn seedMany(comptime G: type, r: Rels(G), n: usize) !void {
    var users: std.ArrayList(User) = .empty;
    defer users.deinit(testing.allocator);
    var posts: std.ArrayList(Post) = .empty;
    defer posts.deinit(testing.allocator);
    var comments: std.ArrayList(Comment) = .empty;
    defer comments.deinit(testing.allocator);
    for (0..n) |i| {
        const id: u32 = @intCast(i + 1);
        try users.append(testing.allocator, .{ .id = id, .name = "u", .email = "u@example.com", .age = 20, .deleted_at = null });
        if (i % 2 != 0) continue;
        for ([_][]const u8{ "a", "b" }, 0..) |title, j| {
            const post_id: u32 = 2 * id + @as(u32, @intCast(j));
            try posts.append(testing.allocator, .{ .id = post_id, .user_id = id, .title = title, .published = true });
            try comments.append(testing.allocator, .{ .id = post_id, .post_id = post_id, .body = "c" });
        }
    }
    try testing.expectEqual(users.items.len, try r.users.createMany(users.items).commit());
    try testing.expectEqual(posts.items.len, try r.posts.createMany(posts.items).commit());
    try testing.expectEqual(comments.items.len, try r.comments.createMany(comments.items).commit());
}

const max_in = zom.Query(Post).max_in;
const max_filters = zom.Query(Post).max_filters;

fn divCeil(n: usize, d: usize) usize {
    return std.math.divCeil(usize, n, d) catch unreachable;
}

const Author = struct { id: u32, full_name: []const u8, posts: []const Post };
const AuthorMapper = zom.Mapper(User, Author, .{
    .renames = &.{.{ .from = "name", .to = "full_name" }},
});
const Writer = struct { id: u32, name: []const u8, posts: []const Post };

// -- the core scenarios ----------------------------------------------------------

test "pg combine(.posts): has-many, one child query, strings in the arena" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try seed(Full, r);
    Rels(Full).reset();

    var result = try r.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, r.posts.where(.published, .eq, true).order(.id, .asc))
        .mapWith(AuthorMapper, testing.allocator);
    defer result.deinit();
    const authors = result.items;

    try testing.expectEqual(1, Full.Dataset(Users).reads);
    try testing.expectEqual(1, Full.Dataset(Posts).reads);
    try testing.expectEqual(2, authors.len);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
    try testing.expectEqual(1, authors[0].posts.len);
    try testing.expectEqualStrings("Relations are values", authors[0].posts[0].title);
    try testing.expectEqual(1, authors[1].posts.len);
    try testing.expectEqualStrings("Comptime schemas", authors[1].posts[0].title);
}

test "pg combine: a parent with no children gets an empty slice; orphans are dropped" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try seed(Full, r);

    // Only user 3's post (13) and the orphan (14) match; user 3 is filtered out.
    var result = try r.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, r.posts.where(.id, .gte, 13))
        .mapTo(Writer, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(2, result.items.len);
    for (result.items) |w| try testing.expectEqual(0, w.posts.len);
}

test "pg combine: children keep the target relation's order within each parent" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try seed(Full, r);

    var result = try r.users.byPk(1).combine(.posts, r.posts.order(.id, .desc)).mapTo(Writer, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(1, result.items.len);
    const posts = result.items[0].posts;
    try testing.expectEqual(2, posts.len);
    try testing.expectEqual(11, posts[0].id);
    try testing.expectEqual(10, posts[1].id);
}

test "pg combine: the parent's limit applies to parents, and no keys means no child query" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try seed(Full, r);

    Rels(Full).reset();
    var one = try r.users.order(.id, .desc).limit(1).combine(.posts, r.posts).mapTo(Writer, testing.allocator);
    defer one.deinit();
    try testing.expectEqual(1, one.items.len);
    try testing.expectEqualStrings("Wanjiru", one.items[0].name);
    try testing.expectEqual(1, one.items[0].posts.len);
    try testing.expectEqual(1, Full.Dataset(Posts).reads);

    Rels(Full).reset();
    var none = try r.users.where(.id, .gt, 100).combine(.posts, r.posts).mapTo(Writer, testing.allocator);
    defer none.deinit();
    try testing.expectEqual(0, none.items.len);
    try testing.expectEqual(0, Full.Dataset(Posts).reads);
}

const PostWithAuthor = struct {
    id: u32,
    title: []const u8,
    author: ?struct { id: u32, name: []const u8 },
};

test "pg combine(.author): belongs-to gives each child its parent, or null" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try seed(Full, r);
    Rels(Full).reset();

    var result = try r.posts.order(.id, .asc)
        .combine(.author, r.users.where(.deleted_at, .eq, null))
        .mapTo(PostWithAuthor, testing.allocator);
    defer result.deinit();
    const posts = result.items;

    try testing.expectEqual(1, Full.Dataset(Users).reads);
    try testing.expectEqual(5, posts.len);
    try testing.expectEqualStrings("Achieng", posts[0].author.?.name);
    try testing.expectEqualStrings("Achieng", posts[1].author.?.name);
    try testing.expectEqualStrings("Otieno", posts[2].author.?.name);
    // User 3 is filtered out of the target relation, and user 9 doesn't exist.
    try testing.expect(posts[3].author == null);
    try testing.expect(posts[4].author == null);
}

test "pg combine: more keys than max_in are read in ceil(keys / max_in) queries" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    const n_users = 2 * max_in + 5;
    try seedMany(Full, r, n_users);
    Rels(Full).reset();

    var result = try r.users.order(.id, .asc).combine(.posts, r.posts.order(.id, .asc)).mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(divCeil(n_users, max_in), Full.Dataset(Posts).reads);
    try testing.expectEqual(max_in, Full.Dataset(Posts).max_params);
    try expectMany(result.items, n_users);
}

test "pg combine: a paged target relation is refused" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try testing.expectError(
        error.PagedCombineTarget,
        r.users.combine(.posts, r.posts.limit(1)).mapTo(Writer, testing.allocator),
    );
}

// -- bind parameters -------------------------------------------------------------

test "pg combine: the batched whereIn on a target with max_filters - 1 filters stays within max_filters * max_in params" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    const n_users = 2 * max_in + 5;
    try seedMany(Full, r, n_users);

    // The fullest target combine can still add its `in` to: every other
    // filter is a full `not_in` list, of post ids that don't exist.
    var absent: [max_in]u32 = undefined;
    for (&absent, 0..) |*id, i| id.* = @intCast(1_000_000 + i);
    var target = r.posts.order(.id, .asc);
    for (0..max_filters - 1) |_| target = target.whereNotIn(.id, &absent);
    try testing.expectEqual(max_filters - 1, target.query.filter_count);

    Rels(Full).reset();
    var result = try r.users.order(.id, .asc).combine(.posts, target).mapTo(Writer, testing.allocator);
    defer result.deinit();

    // Each batch: 15 lists of 64, and up to 64 keys. Postgres takes 65535.
    try testing.expectEqual(divCeil(n_users, max_in), Full.Dataset(Posts).reads);
    try testing.expectEqual(max_filters * max_in, Full.Dataset(Posts).max_params);
    try testing.expect(Full.Dataset(Posts).max_params <= std.math.maxInt(u16));
    try expectMany(result.items, n_users);
}

// -- caller-owned strings: projected and fallback reads ----------------------------

const Title = struct { id: u32, title: []const u8 };
const Byline = struct { id: u32, name: []const u8, posts: []const Title };

test "pg combine: projected source and target are read with readProjected, strings in the arena" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try seed(Full, r);
    Rels(Full).reset();

    var result = try r.users.select(.{ .id, .name }).where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, r.posts.select(.{ .id, .user_id, .title }).order(.id, .asc))
        .mapTo(Byline, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(1, Full.Dataset(Users).projected_reads);
    try testing.expectEqual(1, Full.Dataset(Posts).projected_reads);
    try testing.expectEqual(2, result.items.len);
    try testing.expectEqualStrings("Achieng", result.items[0].name);
    try testing.expectEqual(2, result.items[0].posts.len);
    try testing.expectEqualStrings("Mappers, not models", result.items[0].posts[1].title);
    try testing.expectEqualStrings("Comptime schemas", result.items[1].posts[0].title);
}

test "pg combine: fallback reads drop the strings of the rows they filter out into the arena" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: NoLike = .{ .inner = &db.gw };
    const r = try Rels(NoLike).init(&gw);
    try seed(NoLike, r);
    NoLike.Dataset(Users).reset();
    NoLike.Dataset(Posts).reset();

    // `like` runs in memory on both sides, and the target is also
    // projected, so its whole tuples are mapped down after the filter.
    var result = try r.users.allowFallback().where(.email, .like, "%e%@%").order(.id, .asc)
        .combine(.posts, r.posts.allowFallback().select(.{ .id, .user_id, .title }).where(.title, .like, "%a%").order(.id, .asc))
        .mapTo(Byline, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(1, NoLike.Dataset(Users).reads);
    try testing.expectEqual(1, NoLike.Dataset(Posts).reads);
    try testing.expectEqual(0, NoLike.Dataset(Posts).projected_reads);
    // Wanjiru's email has no `e` before the `@`; every kept post has an `a`.
    try testing.expectEqual(2, result.items.len);
    try testing.expectEqualStrings("Achieng", result.items[0].name);
    try testing.expectEqual(2, result.items[0].posts.len);
    try testing.expectEqual(10, result.items[0].posts[0].id);
    try testing.expectEqual(11, result.items[0].posts[1].id);
    try testing.expectEqualStrings("Otieno", result.items[1].name);
    try testing.expectEqual(1, result.items[1].posts.len);
    try testing.expectEqualStrings("Comptime schemas", result.items[1].posts[0].title);
}

test "pg combine: a whereIn the dataset can't run is a full scan per batch, freed with the result" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: NoIn = .{ .inner = &db.gw };
    const r = try Rels(NoIn).init(&gw);
    const n_users = 2 * max_in + 5;
    try seedMany(NoIn, r, n_users);
    NoIn.Dataset(Posts).reset();

    var result = try r.users.order(.id, .asc)
        .combine(.posts, r.posts.allowFallback().order(.id, .asc))
        .mapTo(Writer, testing.allocator);
    defer result.deinit();

    // Every batch reads every post, and keeps those of its own keys.
    try testing.expectEqual(divCeil(n_users, max_in), NoIn.Dataset(Posts).reads);
    try testing.expectEqual(0, NoIn.Dataset(Posts).max_params);
    try expectMany(result.items, n_users);
}

// -- nested ------------------------------------------------------------------------

const CommentBody = struct { id: u32, body: []const u8 };
const PostWithComments = struct { id: u32, title: []const u8, comments: []const CommentBody };
const AuthorWithComments = struct { id: u32, name: []const u8, posts: []const PostWithComments };

test "pg nested combine: users -> posts -> comments, one query per level" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    try seed(Full, r);
    Rels(Full).reset();

    var result = try r.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, r.posts.order(.id, .asc).combine(.comments, r.comments.order(.id, .desc)))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(1, Full.Dataset(Users).reads);
    try testing.expectEqual(1, Full.Dataset(Posts).reads);
    try testing.expectEqual(1, Full.Dataset(Comments).reads);
    const authors = result.items;
    try testing.expectEqual(2, authors.len);
    try testing.expectEqual(2, authors[0].posts.len);
    try testing.expectEqual(2, authors[0].posts[0].comments.len);
    try testing.expectEqualStrings("Nzuri sana", authors[0].posts[0].comments[0].body);
    try testing.expectEqualStrings("Asante", authors[0].posts[0].comments[1].body);
    try testing.expectEqual(0, authors[0].posts[1].comments.len);
    try testing.expectEqual(1, authors[1].posts[0].comments.len);
    try testing.expectEqualStrings("Comptime!", authors[1].posts[0].comments[0].body);
}

test "pg nested combine: each level makes ceil(keys / max_in) queries" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: Full = .{ .inner = &db.gw };
    const r = try Rels(Full).init(&gw);
    const n_users = 2 * max_in + 5;
    try seedMany(Full, r, n_users);
    Rels(Full).reset();

    var result = try r.users.order(.id, .asc)
        .combine(.posts, r.posts.order(.id, .asc).combine(.comments, r.comments))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();

    const n_posts = 2 * divCeil(n_users, 2);
    try testing.expectEqual(divCeil(n_users, max_in), Full.Dataset(Posts).reads);
    try testing.expectEqual(divCeil(n_posts, max_in), Full.Dataset(Comments).reads);
    try testing.expectEqual(n_users, result.items.len);
    for (result.items, 0..) |a, i| {
        try testing.expectEqual(@as(usize, if (i % 2 == 0) 2 else 0), a.posts.len);
        for (a.posts) |p| {
            try testing.expectEqual(1, p.comments.len);
            try testing.expectEqual(p.id, p.comments[0].id);
        }
    }
}

// -- allocation failures -----------------------------------------------------------

test "pg combine: the result frees cleanly when allocation fails partway, through every read path" {
    var db: Db = undefined;
    try db.open();
    defer db.close();
    var gw: NoLike = .{ .inner = &db.gw };
    const r = try Rels(NoLike).init(&gw);
    try seed(NoLike, r);

    const run = struct {
        fn run(allocator: Allocator, rels: Rels(NoLike)) !void {
            // Plain reads at the top, a projected one in the middle, and a
            // fallback one that filters in memory at the bottom.
            const Leaf = struct { id: u32, body: []const u8 };
            const Mid = struct { id: u32, title: []const u8, comments: []const Leaf };
            const Top = struct { id: u32, name: []const u8, email: []const u8, posts: []const Mid };
            var result = try rels.users.order(.id, .asc)
                .combine(.posts, rels.posts.select(.{ .id, .user_id, .title })
                    .combine(.comments, rels.comments.allowFallback().where(.body, .like, "%a%")))
                .mapTo(Top, allocator);
            defer result.deinit();
            try testing.expectEqual(3, result.items.len);
            try testing.expectEqual(2, result.items[0].posts[0].comments.len);
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{r});
}

fn expectMany(items: []const Writer, n_users: usize) !void {
    try testing.expectEqual(n_users, items.len);
    for (items, 0..) |w, i| {
        try testing.expectEqual(@as(u32, @intCast(i + 1)), w.id);
        try testing.expectEqual(@as(usize, if (i % 2 == 0) 2 else 0), w.posts.len);
        for (w.posts) |p| try testing.expectEqual(w.id, p.user_id);
        if (w.posts.len == 2) {
            try testing.expectEqualStrings("a", w.posts[0].title);
            try testing.expectEqualStrings("b", w.posts[1].title);
        }
    }
}
