//! Joins users read from `data/users.csv` with posts held in memory, through
//! one `zom.Container`. Two adapters, one API: the relations differ only in
//! the gateway they name.
//!
//!   zig build run

const std = @import("std");
const zom = @import("zom");
const zom_csv = @import("zom_csv");

const User = struct { id: u32, name: []const u8, email: []const u8 };
const Post = struct { id: u32, user_id: u32, title: []const u8 };

/// What gets printed: a user with their posts attached.
const Author = struct { id: u32, name: []const u8, email: []const u8, posts: []const Post = &.{} };

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway, .files = zom_csv.Gateway },
    .relations = .{
        .users = .{ zom.Schema(User, "users", .id, .{}), .files },
        .posts = .{ zom.Schema(Post, "posts", .id, .{}), .default },
    },
});

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    // `.files` reads `data/users.csv` for the `users` schema. `.default`
    // needs no settings.
    var app: App = undefined;
    try app.init(gpa, .{ .files = .{ .io = io, .path = "data" } });
    defer app.deinit();

    const users = app.relations.users;
    const posts = app.relations.posts;

    _ = try posts.createMany(&.{
        .{ .id = 10, .user_id = 1, .title = "Relations are values" },
        .{ .id = 11, .user_id = 3, .title = "Reading CSV with zom" },
        .{ .id = 12, .user_id = 1, .title = "Gateways side by side" },
    }).commit();

    // combineMany allocates one slice per author, so give it an arena.
    // Phase 4 replaces it with `combine`.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const authors = try users.order(.id, .asc).mapTo(Author, a);
    try zom.combineMany(
        .{ .into = "posts", .parent_key = "id", .child_key = "user_id" },
        a,
        authors,
        try posts.order(.id, .asc).toSlice(a),
    );

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    for (authors) |author| {
        try out.print("{s} <{s}>\n", .{ author.name, author.email });
        if (author.posts.len == 0) try out.writeAll("  (no posts)\n");
        for (author.posts) |post| try out.print("  - {s}\n", .{post.title});
    }
    try out.flush();
}
