const std = @import("std");
const testing = std.testing;
const zom = @import("../root.zig");
const fixtures = @import("fixtures.zig");

const UserTuple = fixtures.UserTuple;
const PostTuple = fixtures.PostTuple;
const Post = fixtures.Post;
const Author = fixtures.Author;
const AuthorMapper = fixtures.AuthorMapper;

const UserSchema = zom.Schema(UserTuple, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(PostTuple, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
        pub const comments = zom.hasMany(CommentSchema, .post_id);
    },
});
const CommentTuple = struct { id: u32, post_id: u32, body: []const u8 };
const CommentSchema = zom.Schema(CommentTuple, "comments", .id, .{
    .associations = struct {
        pub const post = zom.belongsTo(PostSchema, .post_id);
    },
});

/// A memory gateway whose datasets count their reads, so a test can assert
/// how many queries a combine made. It pages each group itself
/// (`supports.per_group_limit`, from memory's store).
const CountingGateway = CountingGatewayOf(blk: {
    var all: zom.Supports = .all;
    all.projection = false;
    break :blk all;
});
/// The same without `per_group_limit`: combine pages each parent's rows.
const PagingInCombine = CountingGatewayOf(blk: {
    var s: zom.Supports = .all;
    s.projection = false;
    s.per_group_limit = false;
    break :blk s;
});
/// With `per_group_limit`, but no `like`, which a `.fallback` relation
/// then filters in memory.
const NoLike = CountingGatewayOf(blk: {
    var s: zom.Supports = .all;
    s.projection = false;
    s.like = false;
    break :blk s;
});

/// With `per_group_limit`, but no `offset`, which a `.fallback` relation
/// then skips in memory.
const NoOffset = CountingGatewayOf(blk: {
    var s: zom.Supports = .all;
    s.projection = false;
    s.offset = false;
    break :blk s;
});

fn CountingGatewayOf(comptime s: zom.Supports) type {
    return struct {
        const Gw = @This();
        pub const adapter_name = "counting";
        pub const Config = struct {};

        inner: zom.memory.Gateway,

        pub fn init(allocator: std.mem.Allocator, _: Config) Gw {
            return .{ .inner = .init(allocator, .{}) };
        }

        pub fn deinit(self: *Gw) void {
            self.inner.deinit();
        }

        pub fn Dataset(comptime S: type) type {
            return struct {
                const Self = @This();
                const T = S.Tuple;
                const Q = zom.Query(T);
                pub const supports: zom.Supports = s;

                store: *zom.memory.Store(S) = undefined,
                reads: usize = 0,
                /// The rows `read` returned, and how many of its queries were
                /// paged per group.
                rows_read: usize = 0,
                per_group_reads: usize = 0,

                pub fn read(self: *Self, query: Q, allocator: std.mem.Allocator) ![]T {
                    self.reads += 1;
                    if (query.per_group != null) self.per_group_reads += 1;
                    const rows = try self.store.read(query, allocator);
                    self.rows_read += rows.len;
                    return rows;
                }
                pub fn count(self: *Self, query: Q) !usize {
                    return self.store.count(query);
                }
                pub fn insert(self: *Self, row: T) !T {
                    return self.store.insert(row);
                }
            };
        }

        pub fn dataset(self: *Gw, comptime S: type) !*Dataset(S) {
            const static = struct {
                var instance: Dataset(S) = .{};
            };
            static.instance = .{ .store = try self.inner.dataset(S) };
            return &static.instance;
        }
    };
}

fn Fixture(comptime G: type) type {
    return struct {
        gw: G,
        users: zom.Relation(UserSchema, G),
        posts: zom.Relation(PostSchema, G),

        fn init(self: *@This()) !void {
            self.gw = G.init(testing.allocator, .{});
            errdefer self.gw.deinit();
            self.users = try .init(&self.gw);
            self.posts = try .init(&self.gw);
            // The same rows as fixtures.seed, plus a post by a user who
            // doesn't exist.
            const users = self.users;
            const posts = self.posts;
            _ = try users.create(.{ .id = 1, .name = "Achieng", .email = "achieng@example.com", .age = 31, .role = .admin }).commit();
            _ = try users.create(.{ .id = 2, .name = "Otieno", .email = "otieno@example.com", .age = 24 }).commit();
            _ = try users.create(.{ .id = 3, .name = "Wanjiru", .email = "wanjiru@example.com", .age = 42, .deleted_at = 1_700_000_000 }).commit();
            _ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values", .published = true }).commit();
            _ = try posts.create(.{ .id = 11, .user_id = 1, .title = "Mappers, not models", .published = false }).commit();
            _ = try posts.create(.{ .id = 12, .user_id = 2, .title = "Comptime schemas", .published = true }).commit();
            _ = try posts.create(.{ .id = 13, .user_id = 3, .title = "Soft deletes", .published = true }).commit();
            _ = try posts.create(.{ .id = 14, .user_id = 9, .title = "Orphan", .published = true }).commit();
        }

        fn deinit(self: *@This()) void {
            self.gw.deinit();
        }
    };
}

test "combine(.posts) gives what combineMany gave, with one child query" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;
    post_reads.* = 0;

    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.where(.published, .eq, true).order(.id, .asc))
        .mapWith(AuthorMapper, testing.allocator);
    defer result.deinit();
    const authors = result.items;

    try testing.expectEqual(1, post_reads.*);
    try testing.expectEqual(2, authors.len);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
    try testing.expectEqual(1, authors[0].posts.len);
    try testing.expectEqualStrings("Relations are values", authors[0].posts[0].title);
    try testing.expectEqual(1, authors[1].posts.len);
    try testing.expectEqualStrings("Comptime schemas", authors[1].posts[0].title);
}

const Writer = struct { id: u32, name: []const u8, posts: []const Post };

/// `posts` has no default: combine rebuilds this `zom.Mapper` to leave it.
const Renamed = struct { id: u32, full_name: []const u8, posts: []const Post };
const RenamedMapper = zom.Mapper(UserTuple, Renamed, .{ .renames = &.{.{ .from = "name", .to = "full_name" }} });

test "combine: mapWith a zom.Mapper whose entity gives the association field no default" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.order(.id, .asc))
        .mapWith(RenamedMapper, testing.allocator);
    defer result.deinit();

    try testing.expectEqualStrings("Achieng", result.items[0].full_name);
    try expectPostIds(&.{ 10, 11 }, result.items[0].posts);
    try expectPostIds(&.{12}, result.items[1].posts);
}

/// A mapper written by hand, not with `zom.Mapper`: combine uses it as is,
/// so `call` sets `posts` (`Writer.posts` has no default), and combine
/// overwrites it.
const ShoutingMapper = struct {
    pub const Input = UserTuple;
    pub const Output = Writer;

    pub fn call(u: UserTuple) Writer {
        return .{ .id = u.id, .name = if (u.role == .admin) "ADMIN" else u.name, .posts = &.{} };
    }
};

test "combine: mapWith takes a hand-written mapper, and fills its association field" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.order(.id, .asc))
        .mapWith(ShoutingMapper, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(2, result.items.len);
    try testing.expectEqualStrings("ADMIN", result.items[0].name);
    try testing.expectEqual(2, result.items[0].posts.len);
    try testing.expectEqualStrings("Mappers, not models", result.items[0].posts[1].title);
    try testing.expectEqualStrings("Otieno", result.items[1].name);
    try testing.expectEqual(1, result.items[1].posts.len);
}

test "combine: a parent with no children gets an empty slice; orphans are dropped" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    // Only user 3's post (13) and the orphan (14) match; user 3 is filtered out.
    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.where(.id, .gte, 13))
        .mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(2, result.items.len);
    for (result.items) |w| try testing.expectEqual(0, w.posts.len);
}

test "combine: children keep the target relation's order within each parent" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    var result = try f.users.byPk(1).combine(.posts, f.posts.order(.id, .desc)).mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(1, result.items.len);
    const posts = result.items[0].posts;
    try testing.expectEqual(2, posts.len);
    try testing.expectEqual(11, posts[0].id);
    try testing.expectEqual(10, posts[1].id);
}

test "combine: the parent's limit applies to parents, and no keys means no child query" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;

    post_reads.* = 0;
    var one = try f.users.order(.id, .desc).limit(1).combine(.posts, f.posts).mapTo(Writer, testing.allocator);
    defer one.deinit();
    try testing.expectEqual(1, one.items.len);
    try testing.expectEqualStrings("Wanjiru", one.items[0].name);
    try testing.expectEqual(1, one.items[0].posts.len);
    try testing.expectEqual(1, post_reads.*);

    post_reads.* = 0;
    var none = try f.users.where(.id, .gt, 100).combine(.posts, f.posts).mapTo(Writer, testing.allocator);
    defer none.deinit();
    try testing.expectEqual(0, none.items.len);
    try testing.expectEqual(0, post_reads.*);
}

test "combine: a target already at max_filters or max_nodes is error.CombineTargetFull" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;
    const Q = @TypeOf(f.posts).Q;

    // One filter short: combine's `whereIn` is the last one, and it reads.
    var room = f.posts;
    for (0..Q.max_filters - 1) |_| room = room.where(.id, .neq, 99);
    var ok = try f.users.order(.id, .asc).combine(.posts, room).mapTo(Writer, testing.allocator);
    defer ok.deinit();
    try testing.expectEqual(2, ok.items[0].posts.len);

    // Every filter taken, by the user: a named error, not a panic in
    // Query.reserve, and no target read, even with no keys.
    const full = room.where(.id, .neq, 98);
    try testing.expectEqual(@as(usize, Q.max_filters), full.query.filter_count);
    post_reads.* = 0;
    try testing.expectError(error.CombineTargetFull, f.users.combine(.posts, full).mapTo(Writer, testing.allocator));
    try testing.expectError(error.CombineTargetFull, f.users.where(.id, .gt, 100).combine(.posts, full).mapTo(Writer, testing.allocator));
    try testing.expectEqual(0, post_reads.*);

    // Every node taken with filters to spare: not(not(x)) is three nodes
    // for one filter.
    var nodes = f.posts;
    for (0..(Q.max_nodes - 2) / 3) |_| nodes = nodes.whereNot(zom.not(.{ .id, .neq, 99 }));
    nodes = nodes.whereNot(.{ .id, .eq, 99 });
    try testing.expectEqual(@as(u8, Q.max_nodes), nodes.query.node_count);
    try testing.expect(nodes.query.filter_count < Q.max_filters);
    try testing.expectError(error.CombineTargetFull, f.users.combine(.posts, nodes).mapTo(Writer, testing.allocator));

    // The inner level of a nested combine is checked the same way.
    const Inner = struct { id: u32, title: []const u8, comments: []const CommentTuple };
    const Outer = struct { id: u32, posts: []const Inner };
    var comments = try zom.Relation(CommentSchema, CountingGateway).init(&f.gw);
    for (0..Q.max_filters) |_| comments = comments.where(.id, .neq, 99);
    try testing.expectError(
        error.CombineTargetFull,
        f.users.combine(.posts, f.posts.combine(.comments, comments)).mapTo(Outer, testing.allocator),
    );
}

const PostWithAuthor = struct {
    id: u32,
    title: []const u8,
    author: ?struct { id: u32, name: []const u8 },
};

test "combine(.author): belongs-to gives each child its parent, or null" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const user_reads = &(try f.gw.dataset(UserSchema)).reads;
    user_reads.* = 0;

    var result = try f.posts.order(.id, .asc)
        .combine(.author, f.users.where(.deleted_at, .eq, null))
        .mapTo(PostWithAuthor, testing.allocator);
    defer result.deinit();
    const posts = result.items;

    try testing.expectEqual(1, user_reads.*);
    try testing.expectEqual(5, posts.len);
    try testing.expectEqualStrings("Achieng", posts[0].author.?.name);
    try testing.expectEqualStrings("Achieng", posts[1].author.?.name);
    try testing.expectEqualStrings("Otieno", posts[2].author.?.name);
    // User 3 is filtered out of the target relation, and user 9 doesn't exist.
    try testing.expect(posts[3].author == null);
    try testing.expect(posts[4].author == null);
}

// u128 keys, as TigerBeetle account ids are: above u64, so they go
// through `Value.uint128` in whereIn and are hashed as u128.
const Ledger = struct { id: u128, name: []const u8 };
const Entry = struct { id: u128, ledger_id: ?u128, amount: u64 };
const LedgerSchema = zom.Schema(Ledger, "ledgers", .id, .{
    .associations = struct {
        pub const entries = zom.hasMany(EntrySchema, .ledger_id);
    },
});
const EntrySchema = zom.Schema(Entry, "entries", .id, .{
    .associations = struct {
        pub const ledger = zom.belongsTo(LedgerSchema, .ledger_id);
    },
});

test "combine: u128 keys group above u64, both ways" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const ledgers = try zom.Relation(LedgerSchema, zom.memory.Gateway).init(&gw);
    const entries = try zom.Relation(EntrySchema, zom.memory.Gateway).init(&gw);
    const big: u128 = std.math.maxInt(u64) + 1;
    const top: u128 = std.math.maxInt(u128);
    _ = try ledgers.create(.{ .id = big, .name = "big" }).commit();
    _ = try ledgers.create(.{ .id = top, .name = "top" }).commit();
    _ = try ledgers.create(.{ .id = 1, .name = "small" }).commit();
    _ = try entries.create(.{ .id = top - 1, .ledger_id = big, .amount = 10 }).commit();
    _ = try entries.create(.{ .id = top - 2, .ledger_id = top, .amount = 20 }).commit();
    _ = try entries.create(.{ .id = top - 3, .ledger_id = big, .amount = 30 }).commit();
    _ = try entries.create(.{ .id = top - 4, .ledger_id = null, .amount = 40 }).commit();

    const WithEntries = struct { id: u128, entries: []const struct { amount: u64 } };
    var by_ledger = try ledgers.order(.id, .asc).combine(.entries, entries.order(.amount, .asc))
        .mapTo(WithEntries, testing.allocator);
    defer by_ledger.deinit();
    try testing.expectEqual(3, by_ledger.items.len);
    try testing.expectEqual(0, by_ledger.items[0].entries.len);
    try testing.expectEqual(big, by_ledger.items[1].id);
    try testing.expectEqual(2, by_ledger.items[1].entries.len);
    try testing.expectEqual(10, by_ledger.items[1].entries[0].amount);
    try testing.expectEqual(30, by_ledger.items[1].entries[1].amount);
    try testing.expectEqual(1, by_ledger.items[2].entries.len);
    try testing.expectEqual(20, by_ledger.items[2].entries[0].amount);

    const WithLedger = struct { amount: u64, ledger: ?struct { name: []const u8 } };
    var by_entry = try entries.order(.amount, .asc).combine(.ledger, ledgers)
        .mapTo(WithLedger, testing.allocator);
    defer by_entry.deinit();
    try testing.expectEqual(4, by_entry.items.len);
    try testing.expectEqualStrings("big", by_entry.items[0].ledger.?.name);
    try testing.expectEqualStrings("top", by_entry.items[1].ledger.?.name);
    try testing.expectEqualStrings("big", by_entry.items[2].ledger.?.name);
    try testing.expect(by_entry.items[3].ledger == null);
}

test "combine: more keys than max_in are read in ceil(keys / max_in) queries" {
    var gw: CountingGateway = .init(testing.allocator, .{});
    defer gw.deinit();
    const users: zom.Relation(UserSchema, CountingGateway) = try .init(&gw);
    const posts: zom.Relation(PostSchema, CountingGateway) = try .init(&gw);

    const max_in = zom.Query(PostTuple).max_in;
    const n_users = 2 * max_in + 5;
    for (0..n_users) |i| {
        const id: u32 = @intCast(i + 1);
        _ = try users.create(.{ .id = id, .name = "u", .email = "u@example.com", .age = 20 }).commit();
        // Every other user has two posts.
        if (i % 2 == 0) {
            _ = try posts.create(.{ .id = 2 * id, .user_id = id, .title = "a", .published = true }).commit();
            _ = try posts.create(.{ .id = 2 * id + 1, .user_id = id, .title = "b", .published = true }).commit();
        }
    }
    const post_reads = &(try gw.dataset(PostSchema)).reads;
    post_reads.* = 0;

    var result = try users.order(.id, .asc).combine(.posts, posts).mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(std.math.divCeil(usize, n_users, max_in) catch unreachable, post_reads.*);
    try testing.expectEqual(n_users, result.items.len);
    for (result.items, 0..) |w, i| {
        try testing.expectEqual(@as(u32, @intCast(i + 1)), w.id);
        try testing.expectEqual(@as(usize, if (i % 2 == 0) 2 else 0), w.posts.len);
        for (w.posts) |p| try testing.expectEqual(w.id, p.user_id);
    }
}

fn expectPostIds(want: []const u32, got: []const Post) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqual(w, g.id);
}

test "combine: the target's limit and offset page each parent's rows, in one query" {
    try expectPerParentPages(CountingGateway);
    try expectPerParentPages(PagingInCombine);
}

/// The per-parent paging scenarios on `G`, whether its dataset pages each
/// group (only the rows kept are read) or combine does (every row is).
fn expectPerParentPages(comptime G: type) !void {
    const pushed = comptime zom.Adapter(G).supports(PostSchema).per_group_limit;
    var f: Fixture(G) = undefined;
    try f.init();
    defer f.deinit();
    const dataset = try f.gw.dataset(PostSchema);
    const post_reads = &dataset.reads;
    const users = f.users.order(.id, .asc);
    const latest = f.posts.order(.id, .desc);

    // The latest post of each user: a limit on the query would give one post in all.
    post_reads.* = 0;
    dataset.rows_read = 0;
    dataset.per_group_reads = 0;
    var one = try users.combine(.posts, latest.limit(1)).mapTo(Writer, testing.allocator);
    defer one.deinit();
    try testing.expectEqual(1, post_reads.*);
    // Pushed down, only the three posts kept come back; paged here, all
    // four of their posts do, and the query has no page.
    try testing.expectEqual(@as(usize, if (pushed) 3 else 4), dataset.rows_read);
    try testing.expectEqual(@intFromBool(pushed), dataset.per_group_reads);
    try testing.expectEqual(3, one.items.len);
    try expectPostIds(&.{11}, one.items[0].posts);
    try expectPostIds(&.{12}, one.items[1].posts);
    try expectPostIds(&.{13}, one.items[2].posts);

    // offset skips within each parent; past the end gives an empty slice.
    var skipped = try users.combine(.posts, latest.offset(1)).mapTo(Writer, testing.allocator);
    defer skipped.deinit();
    try expectPostIds(&.{10}, skipped.items[0].posts);
    try expectPostIds(&.{}, skipped.items[1].posts);
    try expectPostIds(&.{}, skipped.items[2].posts);

    // Both, with the target's filters applied before the page.
    var paged = try users.combine(.posts, f.posts.where(.id, .lt, 13).order(.id, .asc).offset(1).limit(5)).mapTo(Writer, testing.allocator);
    defer paged.deinit();
    try expectPostIds(&.{11}, paged.items[0].posts);
    try expectPostIds(&.{}, paged.items[1].posts);

    // limit(0) gives every parent an empty slice.
    var zero = try users.combine(.posts, f.posts.limit(0)).mapTo(Writer, testing.allocator);
    defer zero.deinit();
    for (zero.items) |w| try expectPostIds(&.{}, w.posts);
}

test "combine: a paged belongs-to target gives the first parent of each page, or null" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();

    var kept = try f.posts.order(.id, .asc).combine(.author, f.users.limit(1)).mapTo(PostWithAuthor, testing.allocator);
    defer kept.deinit();
    try testing.expectEqualStrings("Achieng", kept.items[0].author.?.name);
    try testing.expectEqualStrings("Otieno", kept.items[2].author.?.name);
    try testing.expectEqualStrings("Wanjiru", kept.items[3].author.?.name);
    try testing.expect(kept.items[4].author == null);

    var skipped = try f.posts.order(.id, .asc).combine(.author, f.users.offset(1)).mapTo(PostWithAuthor, testing.allocator);
    defer skipped.deinit();
    for (skipped.items) |p| try testing.expect(p.author == null);
}

test "combine: per-parent paging holds across ceil(keys / max_in) batched queries" {
    try expectPagesAcrossBatches(CountingGateway);
    try expectPagesAcrossBatches(PagingInCombine);
}

fn expectPagesAcrossBatches(comptime G: type) !void {
    const pushed = comptime zom.Adapter(G).supports(PostSchema).per_group_limit;
    var gw: G = .init(testing.allocator, .{});
    defer gw.deinit();
    const users: zom.Relation(UserSchema, G) = try .init(&gw);
    const posts: zom.Relation(PostSchema, G) = try .init(&gw);

    const max_in = zom.Query(PostTuple).max_in;
    const n_users = 2 * max_in + 5;
    for (0..n_users) |i| {
        const id: u32 = @intCast(i + 1);
        _ = try users.create(.{ .id = id, .name = "u", .email = "u@example.com", .age = 20 }).commit();
        for (0..3) |j| {
            const post_id: u32 = @intCast(3 * id + j);
            _ = try posts.create(.{ .id = post_id, .user_id = id, .title = "p", .published = true }).commit();
        }
    }
    const dataset = try gw.dataset(PostSchema);
    dataset.reads = 0;
    dataset.rows_read = 0;

    var result = try users.order(.id, .asc).combine(.posts, posts.order(.id, .desc).offset(1).limit(1)).mapTo(Writer, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(std.math.divCeil(usize, n_users, max_in) catch unreachable, dataset.reads);
    // One post per user read, not three, when the dataset pages them.
    try testing.expectEqual(@as(usize, if (pushed) n_users else 3 * n_users), dataset.rows_read);
    try testing.expectEqual(n_users, result.items.len);
    for (result.items) |w| try expectPostIds(&.{3 * w.id + 1}, w.posts);
}

test "combine: a .fallback target filtered in memory is paged by combine, not the dataset" {
    var f: Fixture(NoLike) = undefined;
    try f.init();
    defer f.deinit();
    const dataset = try f.gw.dataset(PostSchema);
    const users = f.users.order(.id, .asc);

    // The like runs in memory, on every post of the batch: a page the
    // dataset applied first would count the posts it then drops. Achieng's
    // latest post (11, "Mappers...") doesn't match, so her page is post 10.
    dataset.per_group_reads = 0;
    var result = try users.combine(.posts, f.posts.allowFallback().where(.title, .like, "%values%").order(.id, .desc).limit(1))
        .mapTo(Writer, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(0, dataset.per_group_reads);
    try expectPostIds(&.{10}, result.items[0].posts);
    try expectPostIds(&.{}, result.items[1].posts);

    // A .fallback target the dataset runs entirely is still pushed down.
    var pushed = try users.combine(.posts, f.posts.allowFallback().where(.published, .eq, true).order(.id, .desc).limit(1))
        .mapTo(Writer, testing.allocator);
    defer pushed.deinit();
    try testing.expectEqual(1, dataset.per_group_reads);
    try expectPostIds(&.{10}, pushed.items[0].posts);
    try expectPostIds(&.{12}, pushed.items[1].posts);
}

test "combine: a .fallback offset the dataset can't skip is paged by combine" {
    var f: Fixture(NoOffset) = undefined;
    try f.init();
    defer f.deinit();
    const dataset = try f.gw.dataset(PostSchema);

    // Only the page needs memory here: the filters and order would all go
    // to the dataset, but not its offset, so nothing is pushed.
    var result = try f.users.order(.id, .asc).combine(.posts, f.posts.allowFallback().order(.id, .desc).offset(1).limit(1))
        .mapTo(Writer, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(0, dataset.per_group_reads);
    try expectPostIds(&.{10}, result.items[0].posts);
    try expectPostIds(&.{}, result.items[1].posts);
    try expectPostIds(&.{}, result.items[2].posts);

    // A limit alone it can take.
    var latest = try f.users.order(.id, .asc).combine(.posts, f.posts.allowFallback().order(.id, .desc).limit(1))
        .mapTo(Writer, testing.allocator);
    defer latest.deinit();
    try testing.expectEqual(1, dataset.per_group_reads);
    try expectPostIds(&.{11}, latest.items[0].posts);
    try expectPostIds(&.{12}, latest.items[1].posts);
}

test "combine: a paged target frees cleanly when allocation fails partway" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();
    const run = struct {
        fn run(allocator: std.mem.Allocator, users: zom.Relation(UserSchema, zom.memory.Gateway), posts: zom.Relation(PostSchema, zom.memory.Gateway)) !void {
            var result = try users.combine(.posts, posts.order(.id, .desc).offset(1).limit(1)).mapTo(Writer, allocator);
            result.deinit();
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{ f.users, f.posts });
}

test "combine: the result frees cleanly when allocation fails partway" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();
    const run = struct {
        fn run(
            allocator: std.mem.Allocator,
            users: zom.Relation(UserSchema, zom.memory.Gateway),
            posts: zom.Relation(PostSchema, zom.memory.Gateway),
        ) !void {
            var result = try users.combine(.posts, posts).mapWith(AuthorMapper, allocator);
            result.deinit();
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{ f.users, f.posts });
}

// -- nested combines -----------------------------------------------------------

const Comment = struct { id: u32, body: []const u8 };
const PostWithComments = struct { id: u32, title: []const u8, comments: []const Comment };
const AuthorWithComments = struct { id: u32, name: []const u8, posts: []const PostWithComments };

fn seedComments(comments: zom.Relation(CommentSchema, CountingGateway)) !void {
    _ = try comments.create(.{ .id = 100, .post_id = 10, .body = "Asante" }).commit();
    _ = try comments.create(.{ .id = 101, .post_id = 10, .body = "Nzuri sana" }).commit();
    _ = try comments.create(.{ .id = 102, .post_id = 12, .body = "Comptime!" }).commit();
    _ = try comments.create(.{ .id = 103, .post_id = 99, .body = "Orphan comment" }).commit();
}

test "nested combine: users -> posts -> comments, one query per level" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&f.gw);
    try seedComments(comments);
    const user_reads = &(try f.gw.dataset(UserSchema)).reads;
    const post_reads = &(try f.gw.dataset(PostSchema)).reads;
    const comment_reads = &(try f.gw.dataset(CommentSchema)).reads;
    user_reads.* = 0;
    post_reads.* = 0;
    comment_reads.* = 0;

    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.order(.id, .asc).combine(.comments, comments.order(.id, .desc)))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();

    try testing.expectEqual(1, user_reads.*);
    try testing.expectEqual(1, post_reads.*);
    try testing.expectEqual(1, comment_reads.*);

    const authors = result.items;
    try testing.expectEqual(2, authors.len);
    try testing.expectEqualStrings("Achieng", authors[0].name);
    try testing.expectEqual(2, authors[0].posts.len);
    // Post 10's comments, in the comments relation's order (id desc).
    try testing.expectEqual(10, authors[0].posts[0].id);
    try testing.expectEqual(2, authors[0].posts[0].comments.len);
    try testing.expectEqualStrings("Nzuri sana", authors[0].posts[0].comments[0].body);
    try testing.expectEqualStrings("Asante", authors[0].posts[0].comments[1].body);
    try testing.expectEqual(0, authors[0].posts[1].comments.len);
    try testing.expectEqual(1, authors[1].posts.len);
    try testing.expectEqual(1, authors[1].posts[0].comments.len);
    try testing.expectEqualStrings("Comptime!", authors[1].posts[0].comments[0].body);
}

test "nested combine: the inner level reads only the outer level's rows, and none without keys" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&f.gw);
    try seedComments(comments);
    const comment_reads = &(try f.gw.dataset(CommentSchema)).reads;

    // Otieno's only post is 12: comment 102 is all the comments level sees.
    comment_reads.* = 0;
    var one = try f.users.byPk(2)
        .combine(.posts, f.posts.combine(.comments, comments))
        .mapTo(AuthorWithComments, testing.allocator);
    defer one.deinit();
    try testing.expectEqual(1, comment_reads.*);
    try testing.expectEqual(1, one.items[0].posts[0].comments.len);

    // No posts match, so the comments level has no keys and no query.
    comment_reads.* = 0;
    var none = try f.users.order(.id, .asc)
        .combine(.posts, f.posts.where(.id, .gt, 100).combine(.comments, comments))
        .mapTo(AuthorWithComments, testing.allocator);
    defer none.deinit();
    try testing.expectEqual(0, comment_reads.*);
    try testing.expectEqual(3, none.items.len);
    for (none.items) |a| try testing.expectEqual(0, a.posts.len);
}

test "nested combine: belongs-to inside has-many (users -> posts -> author)" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const Byline = struct { id: u32, author: ?struct { name: []const u8 } };
    const Writer2 = struct { name: []const u8, posts: []const Byline };
    var result = try f.users.byPk(1)
        .combine(.posts, f.posts.order(.id, .asc).combine(.author, f.users))
        .mapTo(Writer2, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(2, result.items[0].posts.len);
    for (result.items[0].posts) |p| try testing.expectEqualStrings("Achieng", p.author.?.name);
}

test "nested combine: each level makes ceil(keys / max_in) queries" {
    var gw: CountingGateway = .init(testing.allocator, .{});
    defer gw.deinit();
    const users: zom.Relation(UserSchema, CountingGateway) = try .init(&gw);
    const posts: zom.Relation(PostSchema, CountingGateway) = try .init(&gw);
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&gw);

    const max_in = zom.Query(PostTuple).max_in;
    // max_in + 3 users with two posts each: 2 user batches, and
    // 2 * (max_in + 3) post keys, so 3 post batches for the comments.
    const n_users = max_in + 3;
    for (0..n_users) |i| {
        const id: u32 = @intCast(i + 1);
        _ = try users.create(.{ .id = id, .name = "u", .email = "u@example.com", .age = 20 }).commit();
        for (0..2) |j| {
            const post_id: u32 = @intCast(2 * id + j);
            _ = try posts.create(.{ .id = post_id, .user_id = id, .title = "p", .published = true }).commit();
            _ = try comments.create(.{ .id = post_id, .post_id = post_id, .body = "c" }).commit();
        }
    }
    const post_reads = &(try gw.dataset(PostSchema)).reads;
    const comment_reads = &(try gw.dataset(CommentSchema)).reads;
    post_reads.* = 0;
    comment_reads.* = 0;

    var result = try users.order(.id, .asc)
        .combine(.posts, posts.order(.id, .asc).combine(.comments, comments))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();

    const divCeil = struct {
        fn f(n: usize, d: usize) usize {
            return std.math.divCeil(usize, n, d) catch unreachable;
        }
    }.f;
    try testing.expectEqual(divCeil(n_users, max_in), post_reads.*);
    try testing.expectEqual(divCeil(2 * n_users, max_in), comment_reads.*);
    try testing.expectEqual(n_users, result.items.len);
    for (result.items) |a| {
        try testing.expectEqual(2, a.posts.len);
        for (a.posts) |p| {
            try testing.expectEqual(1, p.comments.len);
            try testing.expectEqual(p.id, p.comments[0].id);
        }
    }
}

test "nested combine: each level pages its own parents, and the inner level reads only the kept rows" {
    var f: Fixture(CountingGateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, CountingGateway) = try .init(&f.gw);
    try seedComments(comments);
    const comment_reads = &(try f.gw.dataset(CommentSchema)).reads;

    // Each user's first post, with that post's latest comment.
    comment_reads.* = 0;
    var result = try f.users.where(.deleted_at, .eq, null).order(.id, .asc)
        .combine(.posts, f.posts.order(.id, .asc).limit(1).combine(.comments, comments.order(.id, .desc).limit(1)))
        .mapTo(AuthorWithComments, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(1, comment_reads.*);
    const authors = result.items;
    try testing.expectEqual(2, authors.len);
    try testing.expectEqual(1, authors[0].posts.len);
    try testing.expectEqual(10, authors[0].posts[0].id);
    try testing.expectEqual(1, authors[0].posts[0].comments.len);
    try testing.expectEqualStrings("Nzuri sana", authors[0].posts[0].comments[0].body);
    try testing.expectEqual(12, authors[1].posts[0].id);
    try testing.expectEqualStrings("Comptime!", authors[1].posts[0].comments[0].body);

    // When the page keeps no posts, the comments level has no keys and reads nothing.
    comment_reads.* = 0;
    var none = try f.users.combine(.posts, f.posts.limit(0).combine(.comments, comments)).mapTo(AuthorWithComments, testing.allocator);
    defer none.deinit();
    try testing.expectEqual(0, comment_reads.*);
}

test "nested combine: one deinit frees the tree, also when allocation fails partway" {
    var f: Fixture(zom.memory.Gateway) = undefined;
    try f.init();
    defer f.deinit();
    const comments: zom.Relation(CommentSchema, zom.memory.Gateway) = try .init(&f.gw);
    _ = try comments.create(.{ .id = 100, .post_id = 10, .body = "Asante" }).commit();
    _ = try comments.create(.{ .id = 101, .post_id = 12, .body = "Comptime!" }).commit();
    const run = struct {
        fn run(
            allocator: std.mem.Allocator,
            users: zom.Relation(UserSchema, zom.memory.Gateway),
            posts: zom.Relation(PostSchema, zom.memory.Gateway),
            cs: zom.Relation(CommentSchema, zom.memory.Gateway),
        ) !void {
            var result = try users.combine(.posts, posts.combine(.comments, cs)).mapTo(AuthorWithComments, allocator);
            result.deinit();
        }
    }.run;
    try testing.checkAllAllocationFailures(testing.allocator, run, .{ f.users, f.posts, comments });
}

// A view (no primary key) on either side of a combine: `hasMany` into it
// is keyed by the parent's key, and its `belongsTo` by the target's.
const LedgerAccount = struct { id: u32, name: []const u8 };
const LedgerBalance = struct { account_id: u32, timestamp: u64, amount: i64 };
const LedgerAccountSchema = zom.Schema(LedgerAccount, "ledger_accounts", .id, .{
    .associations = struct {
        pub const balances = zom.hasMany(LedgerBalanceSchema, .account_id);
    },
});
const LedgerBalanceSchema = zom.Schema(LedgerBalance, "ledger_balances", null, .{
    .associations = struct {
        pub const account = zom.belongsTo(LedgerAccountSchema, .account_id);
    },
});

test "combine into and out of a view without a primary key" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const accounts = try zom.Relation(LedgerAccountSchema, zom.memory.Gateway).init(&gw);
    const balances = try zom.Relation(LedgerBalanceSchema, zom.memory.Gateway).init(&gw);
    _ = try accounts.createMany(&.{ .{ .id = 1, .name = "cash" }, .{ .id = 2, .name = "sales" } }).commit();
    // Timestamp 7 is on both accounts' rows, as one transfer's would be.
    _ = try balances.createMany(&.{
        .{ .account_id = 1, .timestamp = 7, .amount = 5 },
        .{ .account_id = 2, .timestamp = 7, .amount = -5 },
        .{ .account_id = 1, .timestamp = 9, .amount = 8 },
    }).commit();

    var with_balances = try accounts.order(.id, .asc).combine(.balances, balances.order(.timestamp, .asc))
        .mapTo(struct { id: u32, balances: []const LedgerBalance }, testing.allocator);
    defer with_balances.deinit();
    try testing.expectEqual(2, with_balances.items[0].balances.len);
    try testing.expectEqual(1, with_balances.items[1].balances.len);
    try testing.expectEqual(-5, with_balances.items[1].balances[0].amount);

    var with_account = try balances.where(.timestamp, .eq, 7).order(.account_id, .asc).combine(.account, accounts)
        .mapTo(struct { account_id: u32, account: ?LedgerAccount }, testing.allocator);
    defer with_account.deinit();
    try testing.expectEqual(2, with_account.items.len);
    try testing.expectEqualStrings("sales", with_account.items[1].account.?.name);
}
