//! Combines users read from `data/users.csv` with posts held in memory, through
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

const PostSchema = zom.Schema(Post, "posts", .id, .{});
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = .{ .posts = zom.hasMany(PostSchema, .user_id) },
});

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway, .files = zom_csv.Gateway },
    .relations = .{
        .users = .{ UserSchema, .files },
        .posts = .{ PostSchema, .default },
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

    // The users come from the CSV file and their posts from memory: one
    // read of each, whatever gateway they live in. `deinit` frees every
    // author and post.
    var authors = try users.order(.id, .asc).combine(.posts, posts.order(.id, .asc)).mapTo(Author, gpa);
    defer authors.deinit();

    var buf: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const out = &stdout.interface;
    for (authors.items) |author| {
        try out.print("{s} <{s}>\n", .{ author.name, author.email });
        if (author.posts.len == 0) try out.writeAll("  (no posts)\n");
        for (author.posts) |post| try out.print("  - {s}\n", .{post.title});
    }
    try out.flush();
}
