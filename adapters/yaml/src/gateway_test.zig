const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zom = @import("zom");
const root = @import("root.zig");
const Gateway = root.Gateway;
const WritableGateway = root.WritableGateway;

// -- zom.lint ----------------------------------------------------------------

const Layout = enum {
    /// `path = "."`: one `<name>.yaml` per dataset.
    directory,
    /// `path = "data.yaml"`: every dataset in one file.
    single_file,
};

/// Each lint check gets a fresh temp directory. With `seed_files`, the seed
/// rows are written as YAML (through `writeRecords` or `writeDataset`), so
/// lint reads loaded files; without, a writable gateway starts from no file
/// and lint seeds it through `insertMany`. Checks run one at a time, so one
/// slot is enough.
fn LintFactory(comptime G: type, comptime layout: Layout, comptime seed_files: bool) type {
    const Base = struct {
        var tmp: ?testing.TmpDir = null;

        pub fn create(allocator: Allocator) !G {
            std.debug.assert(tmp == null);
            tmp = testing.tmpDir(.{});
            const path = switch (layout) {
                .directory => ".",
                .single_file => "data.yaml",
            };
            return G.init(allocator, .{ .io = testing.io, .dir = tmp.?.dir, .path = path });
        }

        pub fn destroy(g: *G) void {
            g.deinit();
            tmp.?.cleanup();
            tmp = null;
        }
    };
    // `zom.lint` checks for a `seed` declaration, so the unseeded factory
    // must not have one at all.
    if (!seed_files) return Base;
    return struct {
        pub const create = Base.create;
        pub const destroy = Base.destroy;

        pub fn seed(g: *G, comptime S: type, rows: []const S.Tuple) !void {
            var out: std.Io.Writer.Allocating = .init(testing.allocator);
            defer out.deinit();
            switch (layout) {
                .directory => try root.writeRecords(&out.writer, S.Tuple, rows, testing.allocator),
                .single_file => {
                    // Another dataset around it, which loading must skip.
                    try out.writer.writeAll("other:\n  - id: 1\n");
                    try root.writeDataset(&out.writer, S.Tuple, S.name, rows, testing.allocator);
                },
            }
            const name = switch (layout) {
                .directory => S.name ++ ".yaml",
                .single_file => "data.yaml",
            };
            try g.config.dir.writeFile(testing.io, .{ .sub_path = name, .data = out.written() });
        }
    };
}

test "zom.lint: read checks pass, write checks are skipped" {
    try testing.expect(zom.Adapter(Gateway).readOnly(zom.lint.Users));
    try zom.lint.run(Gateway, LintFactory(Gateway, .directory, true));
    try zom.lint.run(Gateway, LintFactory(Gateway, .single_file, true));
}

test "zom.lint: every check passes on WritableGateway, loaded or new file" {
    const A = zom.Adapter(WritableGateway);
    inline for (.{ .writable, .batch_insert, .updatable, .deletable }) |cap| {
        try testing.expect(A.has(zom.lint.Users, cap));
    }
    inline for (.{ Layout.directory, Layout.single_file }) |layout| {
        try zom.lint.run(WritableGateway, LintFactory(WritableGateway, layout, true));
        try zom.lint.run(WritableGateway, LintFactory(WritableGateway, layout, false));
    }
}

// -- loading -----------------------------------------------------------------

const Role = enum { admin, member, null };
const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    role: Role = .member,
};
const Users = zom.Schema(User, "users", .id);
const Post = struct { id: u32, title: []const u8 };
const Posts = zom.Schema(Post, "posts", .id);

/// A temp directory with `data.yaml` holding `text`, and a gateway over it.
fn Fixture(comptime G: type) type {
    return struct {
        const Self = @This();
        tmp: testing.TmpDir,
        gw: G,

        fn init(self: *Self, text: []const u8, config: struct {
            unknown_keys: root.UnknownKeys = .reject,
        }) !void {
            self.tmp = testing.tmpDir(.{});
            errdefer self.tmp.cleanup();
            try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data = text });
            self.gw = G.init(testing.allocator, .{
                .io = testing.io,
                .dir = self.tmp.dir,
                .path = "data.yaml",
                .unknown_keys = config.unknown_keys,
            });
        }

        fn deinit(self: *Self) void {
            self.gw.deinit();
            self.tmp.cleanup();
        }

        fn users(self: *Self) !zom.Relation(Users, G) {
            return zom.Relation(Users, G).init(&self.gw);
        }

        fn all(self: *Self) ![]User {
            const rel = try self.users();
            return rel.order(.id, .asc).toSlice(testing.allocator);
        }

        fn expectError(self: *Self, err: anyerror, message: []const u8) !void {
            try testing.expectError(err, self.users());
            try testing.expectEqualStrings(message, self.gw.diagnostic.message());
        }
    };
}

test "one file holds every dataset; keys in any order, optional and defaulted ones left out" {
    var f: Fixture(Gateway) = undefined;
    try f.init(
        \\# users and their posts
        \\users:
        \\  - name: "Lovelace, Ada"
        \\    role: admin
        \\    id: 1
        \\    age: 36
        \\  - id: 2
        \\    name: Bob
        \\    age: ~
        \\  - id: 3
        \\    name: ''
        \\    age:
        \\posts:
        \\- id: 10
        \\  title: "#1: \"hello\""
    , .{});
    defer f.deinit();
    const rows = try f.all();
    defer testing.allocator.free(rows);
    try testing.expectEqualDeep(&[_]User{
        .{ .id = 1, .name = "Lovelace, Ada", .age = 36, .role = .admin },
        .{ .id = 2, .name = "Bob", .age = null, .role = .member },
        .{ .id = 3, .name = "", .age = null, .role = .member },
    }, rows);

    const posts = try zom.Relation(Posts, Gateway).init(&f.gw);
    const post = (try posts.byPk(10).one(testing.allocator)).?;
    try testing.expectEqualStrings("#1: \"hello\"", post.title);
}

test "a missing required key reports the dataset, the list index and the key" {
    var f: Fixture(Gateway) = undefined;
    try f.init(
        \\users:
        \\  - id: 1
        \\    name: Ada
        \\  - id: 2
        \\    age: 4
        \\
    , .{});
    defer f.deinit();
    try f.expectError(error.SchemaMismatch, "data.yaml:4: users[1]: missing key \"name\"");
}

test "unknown keys are error.SchemaMismatch, or ignored, and listed with missing ones" {
    var f: Fixture(Gateway) = undefined;
    try f.init("users:\n  - id: 1\n    email: a@example.com\n    nick: ada\n", .{});
    defer f.deinit();
    try f.expectError(
        error.SchemaMismatch,
        "data.yaml:2: users[0]: unknown key \"email\"; unknown key \"nick\"; missing key \"name\"",
    );

    var g: Fixture(Gateway) = undefined;
    try g.init("users:\n  - id: 1\n    email: a@example.com\n    name: Ada\n", .{ .unknown_keys = .ignore });
    defer g.deinit();
    const rows = try g.all();
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("Ada", rows[0].name);

    var w: Fixture(WritableGateway) = undefined;
    try w.init("users:\n  - id: 1\n    email: a@example.com\n    name: Ada\n", .{ .unknown_keys = .ignore });
    defer w.deinit();
    try w.expectError(error.SchemaMismatch, "data.yaml:2: users[0]: unknown key \"email\" (sync would drop it)");
}

test "a bad value reports the key's line, the dataset, the index and the field" {
    var f: Fixture(Gateway) = undefined;
    try f.init("users:\n  - id: 1\n    name: Ada\n  - id: 2\n    name: Bob\n    age: old\n", .{});
    defer f.deinit();
    try f.expectError(error.InvalidInt, "data.yaml:6: users[1].age: \"old\" is not an integer from 0 to 255");

    var g: Fixture(Gateway) = undefined;
    try g.init("users:\n  - id: 1\n    name: Ada\n    role: boss\n", .{});
    defer g.deinit();
    try g.expectError(error.InvalidEnum, "data.yaml:4: users[0].role: \"boss\" is not one of: admin, member, null");

    // A quoted empty string is text, not null.
    var h: Fixture(Gateway) = undefined;
    try h.init("users:\n  - id: 1\n    name: Ada\n    age: \"\"\n", .{});
    defer h.deinit();
    try h.expectError(error.InvalidInt, "data.yaml:4: users[0].age: \"\" is not an integer from 0 to 255");
}

test "null is error.UnexpectedNull on a non-optional field, and beats an optional field's default" {
    var f: Fixture(Gateway) = undefined;
    try f.init("users:\n  - id: 1\n    name: ~\n", .{});
    defer f.deinit();
    try f.expectError(error.UnexpectedNull, "data.yaml:3: users[0].name: null, but the field is not optional");

    var g: Fixture(Gateway) = undefined;
    try g.init("users:\n  - id: 1\n    name: Ada\n    role: null\n", .{});
    defer g.deinit();
    try g.expectError(error.UnexpectedNull, "data.yaml:4: users[0].role: null, but the field is not optional");

    // The enum tag `null`, quoted, is text.
    var q: Fixture(Gateway) = undefined;
    try q.init("users:\n  - id: 1\n    name: Ada\n    role: \"null\"\n", .{});
    defer q.deinit();
    const rows = try q.all();
    defer testing.allocator.free(rows);
    try testing.expectEqual(.null, rows[0].role);

    const Defaulted = zom.Schema(struct { id: u32, n: ?u8 = 5 }, "d", .id);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "d.yaml", .data = "d:\n  - id: 1\n    n: ~\n  - id: 2\n" });
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "d.yaml" });
    defer gw.deinit();
    const d = try gw.dataset(Defaulted);
    const got = try d.read(.{}, testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqual(null, got[0].n);
    try testing.expectEqual(5, got[1].n);
}

test "a parse error reports file:line:column" {
    var f: Fixture(Gateway) = undefined;
    try f.init("users:\n  - id: &a 1\n", .{});
    defer f.deinit();
    try f.expectError(error.UnsupportedYaml, "data.yaml:2:9: unsupported YAML: an anchor (&name)");
}

test "a dataset missing from the file is error.NotFound, or empty when writable" {
    var f: Fixture(Gateway) = undefined;
    try f.init("posts: []\n", .{});
    defer f.deinit();
    try f.expectError(error.NotFound, "data.yaml: no dataset 'users'");

    var w: Fixture(WritableGateway) = undefined;
    try w.init("posts: []\n", .{});
    defer w.deinit();
    const users = try w.users();
    try testing.expectEqual(0, try users.count());
}

test "a directory holds one bare sequence per dataset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "data");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data/users.yaml", .data = "\xEF\xBB\xBF---\n- id: 1\n  name: Ada\n" });

    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "data" });
    defer gw.deinit();
    const users = try zom.Relation(Users, Gateway).init(&gw);
    try testing.expectEqual(1, try users.count());

    try testing.expectError(error.NotFound, gw.dataset(Posts));
    try testing.expectEqualStrings("data/posts.yaml: no such file", gw.diagnostic.message());

    // A dataset file is a sequence, not a mapping of datasets.
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data/posts.yaml", .data = "posts:\n  - id: 1\n" });
    try testing.expectError(error.UnsupportedYaml, gw.dataset(Posts));
    try testing.expect(std.mem.startsWith(u8, gw.diagnostic.message(), "data/posts.yaml:1:1: unsupported YAML: a top-level mapping"));
}

test "a missing path is error.NotFound; a file larger than max_file_bytes is error.FileTooBig" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "data.yaml" });
    defer gw.deinit();
    try testing.expectError(error.NotFound, gw.dataset(Users));
    try testing.expectEqualStrings("data.yaml: no such file or directory", gw.diagnostic.message());

    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data = "users:\n  - id: 1\n    name: Ada\n" });
    var small = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "data.yaml", .max_file_bytes = 8 });
    defer small.deinit();
    try testing.expectError(error.FileTooBig, small.dataset(Users));
}

test "loading copies strings and survives running out of memory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data = "users:\n  - id: 1\n    name: \"A\\tda\"\n  - id: 2\n    name: Bob\n" });
    try testing.checkAllAllocationFailures(testing.allocator, loadAll, .{tmp.dir});
}

fn loadAll(allocator: Allocator, dir: std.Io.Dir) !void {
    var gw = Gateway.init(allocator, .{ .io = testing.io, .dir = dir, .path = "data.yaml" });
    defer gw.deinit();
    const d = try gw.dataset(Users);
    const rows = try d.read(.{}, allocator);
    defer allocator.free(rows);
    try testing.expectEqualStrings("A\tda", rows[0].name);
}

// -- writing and sync --------------------------------------------------------

fn expectFile(dir: std.Io.Dir, name: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectNoFile(dir: std.Io.Dir, name: []const u8) !void {
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, name, .{}));
}

/// Strings the writer must quote or escape to read them back.
const tricky = [_][]const u8{
    "123",         "yes",          "No",  "null", "~",           "",          " lead",           "trail ",   "a: b",   "a:",    "# x",     "a #b",
    "a#b",         "-",            "- x", "-x",   "line\nbreak", "tab\there", "quote \" and \\", "'single'", "[list]", "{map}", "&anchor", "*alias",
    "!tag",        "|",            ">",   "%",    "@",           "`",         "---",             "...",      "?",      "1e3",   ".5",      "+1",
    "caf\xC3\xA9", "\x00\x01\x7F", "\r",
};

test "insert, sync, and a new gateway on the same directory reads the rows back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var want: [tricky.len]User = undefined;
    for (&want, tricky, 0..) |*u, name, i| u.* = .{
        .id = @intCast(i + 1),
        .name = name,
        .age = if (i % 3 == 0) null else @intCast(i),
        .role = if (i % 2 == 0) .null else .admin,
    };
    {
        var gw = WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
        defer gw.deinit();
        const users = try zom.Relation(Users, WritableGateway).init(&gw);
        _ = try users.createMany(&want).commit();
        // Nothing reaches the file before sync.
        try expectNoFile(tmp.dir, "users.yaml");
        try gw.sync();
    }
    try expectNoFile(tmp.dir, "users.yaml.tmp");

    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    const users = try zom.Relation(Users, Gateway).init(&gw);
    const rows = try users.order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualDeep(&want, rows);
}

test "sync writes keys in schema order, null as ~, and quotes strings that look typed" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var gw = WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    const users = try zom.Relation(Users, WritableGateway).init(&gw);
    _ = try users.createMany(&.{
        .{ .id = 1, .name = "Lovelace, Ada", .age = 36, .role = .admin },
        .{ .id = 2, .name = "007", .age = null, .role = .null },
    }).commit();
    try gw.sync();
    try expectFile(tmp.dir, "users.yaml",
        \\- id: 1
        \\  name: Lovelace, Ada
        \\  age: 36
        \\  role: admin
        \\- id: 2
        \\  name: "007"
        \\  age: ~
        \\  role: "null"
        \\
    );

    // Deleting every row leaves an empty file, which reads as no rows.
    _ = try users.delete();
    try gw.sync();
    try expectFile(tmp.dir, "users.yaml", "");
}

test "a single-file sync keeps the other datasets, their order and their quoting" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data =
        \\posts:
        \\  - id: 1
        \\    title: "02134"   # quoted: a string
        \\    draft: yes
        \\    note: ~
        \\users:
        \\  - id: 1
        \\    name: Ada
        \\tags: []
        \\
    });
    var gw = WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "data.yaml" });
    defer gw.deinit();
    const users = try zom.Relation(Users, WritableGateway).init(&gw);
    try testing.expectEqual(1, try users.byPk(1).update().set(.age, 40).commit());
    // A dataset the file did not have goes last.
    const Notes = zom.Schema(struct { id: u32 }, "notes", .id);
    _ = try (try gw.dataset(Notes)).insert(.{ .id = 9 });
    try gw.sync();
    try expectFile(tmp.dir, "data.yaml",
        \\posts:
        \\  - id: 1
        \\    title: "02134"
        \\    draft: yes
        \\    note: ~
        \\users:
        \\  - id: 1
        \\    name: Ada
        \\    age: 40
        \\    role: member
        \\tags: []
        \\notes:
        \\  - id: 9
        \\
    );
}

test "a single-file sync rereads the file, so a change made since is kept" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data = "users: []\nposts: []\n" });
    var gw = WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "data.yaml" });
    defer gw.deinit();
    _ = try (try gw.dataset(Users)).insert(.{ .id = 1, .name = "Ada", .age = null });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data = "users: []\nposts:\n  - id: 3\n    title: new\n" });
    try gw.sync();
    try expectFile(tmp.dir, "data.yaml", "users:\n  - id: 1\n    name: Ada\n    age: ~\n    role: member\nposts:\n  - id: 3\n    title: new\n");

    // If it no longer parses, sync fails and leaves it alone.
    const broken = "users: [\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "data.yaml", .data = broken });
    _ = try (try gw.dataset(Users)).insert(.{ .id = 2, .name = "Bob", .age = null });
    try testing.expectError(error.UnsupportedYaml, gw.sync());
    try testing.expectEqualStrings(
        "data.yaml:1:8: unsupported YAML: a flow collection ([...] or {...}) (sync reads the file again to keep its other datasets)",
        gw.diagnostic.message(),
    );
    try expectFile(tmp.dir, "data.yaml", broken);
    try expectNoFile(tmp.dir, "data.yaml.tmp");
}

test "sync writes only dirty datasets; a new file is created; deinit does not sync" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var gw = WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "new.yaml" });
        defer gw.deinit();
        const users = try zom.Relation(Users, WritableGateway).init(&gw);
        try testing.expectEqual(0, try users.byPk(9).delete());
        try gw.sync();
        try expectNoFile(tmp.dir, "new.yaml");

        const posts = try gw.dataset(Posts);
        _ = try posts.insert(.{ .id = 1, .title = "hi" });
        try testing.expect(posts.dirty and !(try gw.dataset(Users)).dirty);
        try gw.sync();
        try testing.expect(!posts.dirty);
        try expectFile(tmp.dir, "new.yaml", "posts:\n  - id: 1\n    title: hi\n");

        _ = try posts.insert(.{ .id = 2, .title = "unsynced" });
    }
    try expectFile(tmp.dir, "new.yaml", "posts:\n  - id: 1\n    title: hi\n");
}

test "a sync that cannot create the temp file leaves the original unchanged and stays dirty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "- id: 1\n  name: Ada\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.yaml", .data = original });
    var gw = WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    _ = try (try gw.dataset(Users)).insert(.{ .id = 2, .name = "Bob", .age = null });

    try tmp.dir.createDirPath(testing.io, "users.yaml.tmp");
    try testing.expectError(error.IsDir, gw.sync());
    try testing.expectEqualStrings("users.yaml: sync failed: IsDir", gw.diagnostic.message());
    try expectFile(tmp.dir, "users.yaml", original);

    try tmp.dir.deleteDir(testing.io, "users.yaml.tmp");
    try gw.sync();
    try expectFile(tmp.dir, "users.yaml", "- id: 1\n  name: Ada\n  age: ~\n  role: member\n- id: 2\n  name: Bob\n  age: ~\n  role: member\n");
}
