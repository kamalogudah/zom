//! A repository and two transactions against Postgres: signing a user up
//! writes the user and their first posts in one transaction, so a failure
//! part way through leaves neither.
//!
//!   docker run --rm -d --name zom-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:17
//!   export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres
//!   psql "$DATABASE_URL" -f schema.sql
//!   zig build run
//!
//! Every run starts by emptying the two tables, so it prints the same thing.

const std = @import("std");
const zom = @import("zom");
const zom_pg = @import("zom_pg");

const User = struct { id: u32, name: []const u8, email: []const u8, deleted_at: ?i64 = null };
const Post = struct { id: u32, user_id: u32, title: []const u8 };

/// What gets printed: a user with their posts attached.
const Author = struct { id: u32, name: []const u8, email: []const u8, posts: []const Post = &.{} };

const PostSchema = zom.Schema(Post, "posts", .id, .{});
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = .{ .posts = zom.hasMany(PostSchema, .user_id) },
});

/// zom-pg logs every Postgres error at debug level, which in a Debug build
/// includes the duplicate key this example causes on purpose. Lower this to
/// `.debug` to see each one while debugging.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{ .scope = .zom_pg, .level = .info }},
};

const App = zom.Container(.{
    .gateways = .{ .db = zom_pg.Gateway },
    .relations = .{
        .users = .{ UserSchema, .db },
        .posts = .{ PostSchema, .db },
    },
});

/// The custom view: rom's `def active = where(deleted_at: nil)`.
const Users = struct {
    rel: @FieldType(App.Relations, "users"),

    pub fn active(self: Users) @TypeOf(self.rel) {
        return self.rel.where(.deleted_at, .eq, null);
    }
};

const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users, .posts = .plain } });

/// What `signUp` needs. Zig has no closures, so the transaction's callback
/// gets its state through a context value.
const SignUp = struct {
    allocator: std.mem.Allocator,
    user: User,
    posts: []const Post,
};

/// Runs inside the transaction: `tx` holds the container's relations,
/// rebound to the transaction's connection. Returning an error rolls the
/// whole sign-up back.
fn signUp(s: SignUp, tx: App.Relations) !usize {
    const repo = UserRepo.fromRelations(tx);
    // zom-pg's strings belong to the caller, so a create that returns the
    // stored row takes an allocator (`commit()` would be a compile error).
    _ = try repo.create(s.user).commitAlloc(s.allocator);
    return repo.relations.posts.createMany(s.posts).commit();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    // An arena for every row read: freed once, when `main` returns.
    const arena = init.arena.allocator();

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;

    const url = try databaseUrl(init);

    var app: App = undefined;
    try app.init(init.gpa, .{ .db = .{ .io = io, .url = url, .pool_size = 2 } });
    defer app.deinit();

    // Fail early, with every mismatch listed, if schema.sql wasn't applied
    // or no longer matches the structs above.
    try verify(&app.gateways.db, UserSchema, arena);
    try verify(&app.gateways.db, PostSchema, arena);
    var repo = UserRepo.init(&app);
    _ = try repo.relations.posts.delete();
    _ = try repo.delete();

    // Wanjiru closed her account: still a row, but not `active`.
    _ = try repo.create(.{ .id = 3, .name = "Wanjiru", .email = "wanjiru@example.com", .deleted_at = 1_700_000_000 }).commitAlloc(arena);

    // A sign-up that commits.
    const n = try app.transaction(.db, SignUp{
        .allocator = arena,
        .user = .{ .id = 1, .name = "Achieng", .email = "achieng@example.com" },
        .posts = &.{
            .{ .id = 10, .user_id = 1, .title = "Relations are values" },
            .{ .id = 11, .user_id = 1, .title = "Transactions roll back" },
        },
    }, signUp);
    try out.print("committed: Achieng, with {d} posts\n", .{n});

    // A sign-up that fails part way: the user row goes in, then the post
    // reuses id 10, which is Achieng's. The deliberate error rolls back
    // the user too.
    if (app.transaction(.db, SignUp{
        .allocator = arena,
        .user = .{ .id = 2, .name = "Baraka", .email = "baraka@example.com" },
        .posts = &.{.{ .id = 10, .user_id = 2, .title = "First!" }},
    }, signUp)) |_| {
        return error.ExpectedRollback;
    } else |err| switch (err) {
        error.DuplicatePrimaryKey => {
            const constraint = if (zom_pg.Gateway.lastError()) |e| e.constraint orelse "?" else "?";
            try out.print("rolled back: {t} ({s})\n", .{ err, constraint });
        },
        else => return err,
    }
    try out.print("  users named Baraka: {d}, posts by user 2: {d}\n", .{
        try repo.where(.name, .eq, "Baraka").count(),
        try repo.relations.posts.where(.user_id, .eq, 2).count(),
    });

    // The view, then the active users with their posts: one query for the
    // users and one `IN (...)` query for the posts.
    try out.print("active users: {d} of {d}\n", .{ try repo.root().active().count(), try repo.all().count() });
    const authors = try repo.root().active().order(.id, .asc)
        .combine(.posts, repo.relations.posts.order(.id, .asc))
        .mapTo(Author, arena);
    for (authors.items) |author| {
        try out.print("{s} <{s}>\n", .{ author.name, author.email });
        for (author.posts) |post| try out.print("  - {s}\n", .{post.title});
    }
    try out.flush();
}

/// The first argument, or else DATABASE_URL.
fn databaseUrl(init: std.process.Init) ![]const u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1) return args[1];
    return init.environ_map.get("DATABASE_URL") orelse {
        std.log.err("no database: set DATABASE_URL, or pass the URL as the first argument", .{});
        return error.NoDatabaseUrl;
    };
}

/// `Gateway.verify`, with each mismatch logged and a hint about schema.sql.
fn verify(gateway: *zom_pg.Gateway, comptime S: type, allocator: std.mem.Allocator) !void {
    var diagnostics: zom_pg.Gateway.Diagnostics = .init(allocator);
    gateway.verify(S, &diagnostics) catch |err| switch (err) {
        error.SchemaMismatch => {
            std.log.err("table '{s}' doesn't match the schema; did you run `psql \"$DATABASE_URL\" -f schema.sql`?\n{f}", .{ S.name, diagnostics });
            return err;
        },
        else => return err,
    };
}
