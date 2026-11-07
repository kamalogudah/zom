const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zom = @import("zom");
const root = @import("root.zig");
const Gateway = root.Gateway;
const WritableGateway = root.WritableGateway;

// -- zom.lint ----------------------------------------------------------------

/// Each lint check gets a fresh temp directory. With `seed_files`, it is
/// seeded with one CSV file per schema through `writeTable`, so lint reads
/// loaded files; without, a writable gateway starts from no file and lint
/// seeds it through `insertMany`. Checks run one at a time, so one slot is
/// enough.
fn LintFactory(comptime G: type, comptime seed_files: bool) type {
    const Base = struct {
        var tmp: ?testing.TmpDir = null;

        pub fn create(allocator: Allocator) !G {
            std.debug.assert(tmp == null);
            tmp = testing.tmpDir(.{});
            return G.init(allocator, .{ .io = testing.io, .dir = tmp.?.dir, .path = "." });
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
            try writeFixture(g.config.dir, S.name ++ ".csv", S.Tuple, rows);
        }
    };
}

fn writeFixture(dir: std.Io.Dir, name: []const u8, comptime T: type, rows: []const T) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try root.writeTable(&out.writer, T, rows, testing.allocator, .{});
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = out.written() });
}

test "zom.lint: read checks pass, write checks are skipped" {
    try testing.expect(zom.Adapter(Gateway).readOnly(zom.lint.Users));
    try zom.lint.run(Gateway, LintFactory(Gateway, true));
}

test "zom.lint: every check passes on WritableGateway, loaded or new file" {
    const A = zom.Adapter(WritableGateway);
    inline for (.{ .writable, .batch_insert, .updatable, .deletable }) |cap| {
        try testing.expect(A.has(zom.lint.Users, cap));
    }
    try zom.lint.run(WritableGateway, LintFactory(WritableGateway, true));
    try zom.lint.run(WritableGateway, LintFactory(WritableGateway, false));
}

// -- loading -----------------------------------------------------------------

const Role = enum { admin, member };
const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    role: Role = .member,
};
const Users = zom.Schema(User, "users", .id, .{});

/// A temp directory with `users.csv` holding `text`, and a gateway over it.
const Fixture = struct {
    tmp: testing.TmpDir,
    gw: Gateway,

    fn init(self: *Fixture, text: []const u8, config: struct {
        unknown_columns: root.UnknownColumns = .reject,
        separator: u8 = ',',
    }) !void {
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = text });
        self.gw = Gateway.init(testing.allocator, .{
            .io = testing.io,
            .dir = self.tmp.dir,
            .path = ".",
            .unknown_columns = config.unknown_columns,
            .separator = config.separator,
        });
    }

    fn deinit(self: *Fixture) void {
        self.gw.deinit();
        self.tmp.cleanup();
    }

    fn users(self: *Fixture) !zom.Relation(Users, Gateway) {
        return zom.Relation(Users, Gateway).init(&self.gw);
    }

    fn expectError(self: *Fixture, err: anyerror, message: []const u8) !void {
        try testing.expectError(err, self.users());
        try testing.expectEqualStrings(message, self.gw.diagnostic.message());
    }
};

test "columns may come in any order" {
    var f: Fixture = undefined;
    try f.init("role,age,name,id\nadmin,36,\"Lovelace, Ada\",1\nmember,,Bob,2\n", .{});
    defer f.deinit();
    const users = try f.users();
    const rows = try users.order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualDeep(&[_]User{
        .{ .id = 1, .name = "Lovelace, Ada", .age = 36, .role = .admin },
        .{ .id = 2, .name = "Bob", .age = null, .role = .member },
    }, rows);
}

test "optional and defaulted columns may be left out" {
    var f: Fixture = undefined;
    try f.init("\xEF\xBB\xBFname,id\r\nAda,1\r\n\r\nBob,2\r\n", .{});
    defer f.deinit();
    const users = try f.users();
    try testing.expectEqual(2, try users.count());
    const bob = (try users.byPk(2).one(testing.allocator)).?;
    try testing.expectEqual(null, bob.age);
    try testing.expectEqual(.member, bob.role);
}

test "the dataset is loaded once and kept" {
    var f: Fixture = undefined;
    try f.init("id,name\n1,Ada\n", .{});
    defer f.deinit();
    const a = try f.gw.dataset(Users);
    try f.tmp.dir.deleteFile(testing.io, "users.csv");
    try testing.expectEqual(a, try f.gw.dataset(Users));
}

test "a missing required column is error.SchemaMismatch" {
    var f: Fixture = undefined;
    try f.init("id,age\n1,3\n", .{});
    defer f.deinit();
    try f.expectError(error.SchemaMismatch, "users.csv: header does not match 'users': missing column \"name\"");
}

test "an unknown column is error.SchemaMismatch, or ignored" {
    var f: Fixture = undefined;
    try f.init("id,name,email,id\n1,Ada,ada@example.com,1\n", .{});
    defer f.deinit();
    try f.expectError(
        error.SchemaMismatch,
        "users.csv: header does not match 'users': unknown column \"email\"; column \"id\" appears twice",
    );

    var g: Fixture = undefined;
    try g.init("id,email,name\n1,ada@example.com,Ada\n", .{ .unknown_columns = .ignore });
    defer g.deinit();
    const users = try g.users();
    const ada = (try users.byPk(1).one(testing.allocator)).?;
    try testing.expectEqualStrings("Ada", ada.name);
}

test "a bad cell reports file:row:col" {
    var f: Fixture = undefined;
    try f.init("name,id,age\nAda,1,36\n\"Bob\nBobson\",2,old\n", .{});
    defer f.deinit();
    try f.expectError(error.InvalidInt, "users.csv:3:3 (age): \"old\" is not an integer from 0 to 255");

    var g: Fixture = undefined;
    try g.init("id;name\n1;Ada\n2;;\n", .{ .separator = ';' });
    defer g.deinit();
    try g.expectError(error.WrongCellCount, "users.csv:3: 3 cells, but the header has 2");

    var h: Fixture = undefined;
    try h.init("id,name\n1,\"Ada\n", .{});
    defer h.deinit();
    try h.expectError(error.UnterminatedQuote, "users.csv:2:3: unterminated quote");

    var e: Fixture = undefined;
    try e.init("", .{});
    defer e.deinit();
    try e.expectError(error.SchemaMismatch, "users.csv: empty file, expected a header row with the fields of 'users'");
}

test "a missing file is error.NotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    try testing.expectError(error.NotFound, gw.dataset(Users));
    try testing.expectEqualStrings("users.csv: no such file", gw.diagnostic.message());

    var missing = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "nope" });
    defer missing.deinit();
    try testing.expectError(error.NotFound, missing.dataset(Users));
}

test "path may be a single file named after the dataset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "data");
    try writeFixture(tmp.dir, "data/users.csv", User, &.{.{ .id = 7, .name = "Ada", .age = 36, .role = .admin }});

    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "data/users.csv" });
    defer gw.deinit();
    const users = try zom.Relation(Users, Gateway).init(&gw);
    try testing.expectEqual(1, try users.count());

    const Posts = zom.Schema(struct { id: u32 }, "posts", .id, .{});
    try testing.expectError(error.NotFound, gw.dataset(Posts));
    try testing.expectEqualStrings("data/users.csv: holds the dataset 'users', not 'posts'", gw.diagnostic.message());
}

test "a file larger than max_file_bytes is error.FileTooBig" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = "id,name\n1,Ada\n" });
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = ".", .max_file_bytes = 8 });
    defer gw.deinit();
    try testing.expectError(error.FileTooBig, gw.dataset(Users));
}

test "writeTable output reads back through the gateway" {
    const rows = [_]User{
        .{ .id = 1, .name = "say \"hi\", Ada", .age = null, .role = .admin },
        .{ .id = 2, .name = "two\nlines", .age = 255, .role = .member },
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFixture(tmp.dir, "users.csv", User, &rows);
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    const users = try zom.Relation(Users, Gateway).init(&gw);
    const got = try users.toSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualDeep(&rows, got);
}

test "loading copies strings and survives running out of memory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = "id,name\n1,\"A\"\"da\"\n2,Bob\n" });
    try testing.checkAllAllocationFailures(testing.allocator, loadAll, .{tmp.dir});
}

fn loadAll(allocator: Allocator, dir: std.Io.Dir) !void {
    var gw = Gateway.init(allocator, .{ .io = testing.io, .dir = dir, .path = "." });
    defer gw.deinit();
    const d = try gw.dataset(Users);
    const rows = try d.read(.{}, allocator);
    defer allocator.free(rows);
    try testing.expectEqualStrings("A\"da", rows[0].name);
}

// -- writing and sync --------------------------------------------------------

fn writable(dir: std.Io.Dir) WritableGateway {
    return WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = dir, .path = "." });
}

fn expectFile(dir: std.Io.Dir, name: []const u8, want: []const u8) !void {
    const got = try dir.readFileAlloc(testing.io, name, testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

fn expectNoFile(dir: std.Io.Dir, name: []const u8) !void {
    try testing.expectError(error.FileNotFound, dir.statFile(testing.io, name, .{}));
}

test "insert, sync, and a new gateway on the same directory reads the rows" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var gw = writable(tmp.dir);
        defer gw.deinit();
        const users = try zom.Relation(Users, WritableGateway).init(&gw);
        _ = try users.create(.{ .id = 1, .name = "Lovelace, Ada", .age = 36, .role = .admin }).commit();
        _ = try users.createMany(&.{
            .{ .id = 2, .name = "Bob", .age = null },
            .{ .id = 3, .name = "Cy", .age = 7 },
        }).commit();
        // Nothing reaches the file before sync.
        try expectNoFile(tmp.dir, "users.csv");
        try gw.sync();
    }
    // A new file gets the columns in schema order.
    try expectFile(tmp.dir, "users.csv",
        \\id,name,age,role
        \\1,"Lovelace, Ada",36,admin
        \\2,Bob,,member
        \\3,Cy,7,member
        \\
    );
    try expectNoFile(tmp.dir, "users.csv.tmp");

    var gw = writable(tmp.dir);
    defer gw.deinit();
    const users = try zom.Relation(Users, WritableGateway).init(&gw);
    const rows = try users.order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqualDeep(&[_]User{
        .{ .id = 1, .name = "Lovelace, Ada", .age = 36, .role = .admin },
        .{ .id = 2, .name = "Bob", .age = null, .role = .member },
        .{ .id = 3, .name = "Cy", .age = 7, .role = .member },
    }, rows);
}

test "sync keeps the header's column order and appends the fields it lacked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = "name,id\r\nAda,1\r\nBob,2\r\nCy,3\r\n" });

    var gw = writable(tmp.dir);
    defer gw.deinit();
    const users = try zom.Relation(Users, WritableGateway).init(&gw);
    try testing.expectEqual(1, try users.byPk(2).update().set(.age, 40).commit());
    try testing.expectEqual(1, try users.byPk(3).delete());
    try gw.sync();
    try expectFile(tmp.dir, "users.csv",
        \\name,id,age,role
        \\Ada,1,,member
        \\Bob,2,40,member
        \\
    );
}

test "sync writes only dirty datasets, and only once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "id,name\n1,Ada\n";
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = original });

    var gw = writable(tmp.dir);
    defer gw.deinit();
    const d = try gw.dataset(Users);
    const Posts = zom.Schema(struct { id: u32 }, "posts", .id, .{});
    const posts = try gw.dataset(Posts);

    // A missing file is an empty dataset, and with no writes stays missing.
    // Writes that change nothing do not mark the dataset dirty either.
    const users = try zom.Relation(Users, WritableGateway).init(&gw);
    try testing.expectEqual(0, try users.byPk(9).delete());
    try testing.expectEqual(0, try d.insertMany(&.{}));
    try gw.sync();
    try expectFile(tmp.dir, "users.csv", original);
    try expectNoFile(tmp.dir, "posts.csv");

    _ = try posts.insert(.{ .id = 1 });
    try testing.expect(posts.dirty and !d.dirty);
    try gw.sync();
    try testing.expect(!posts.dirty);
    try expectFile(tmp.dir, "posts.csv", "id\n1\n");
    try expectFile(tmp.dir, "users.csv", original);
}

test "deinit does not sync" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    {
        var gw = writable(tmp.dir);
        defer gw.deinit();
        _ = try (try gw.dataset(Users)).insert(.{ .id = 1, .name = "Ada", .age = null });
    }
    try expectNoFile(tmp.dir, "users.csv");
}

test "a writable gateway rejects unknown columns even with .ignore" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = "id,email,name\n1,a@example.com,Ada\n" });
    var gw = WritableGateway.init(testing.allocator, .{
        .io = testing.io,
        .dir = tmp.dir,
        .path = ".",
        .unknown_columns = .ignore,
    });
    defer gw.deinit();
    try testing.expectError(error.SchemaMismatch, gw.dataset(Users));
    try testing.expectEqualStrings(
        "users.csv: header does not match 'users': unknown column \"email\" (sync would drop it)",
        gw.diagnostic.message(),
    );
}

test "a writable path may name a CSV file that does not exist yet" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "data");
    var gw = WritableGateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "data/users.csv" });
    defer gw.deinit();
    _ = try (try gw.dataset(Users)).insert(.{ .id = 1, .name = "Ada", .age = 2 });
    try gw.sync();
    try expectFile(tmp.dir, "data/users.csv", "id,name,age,role\n1,Ada,2,member\n");
}

test "sync's line_ending and separator round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var gw = WritableGateway.init(testing.allocator, .{
        .io = testing.io,
        .dir = tmp.dir,
        .path = ".",
        .separator = ';',
        .line_ending = "\r\n",
        .null_text = "NULL",
    });
    defer gw.deinit();
    _ = try (try gw.dataset(Users)).insert(.{ .id = 1, .name = "a;b", .age = null });
    try gw.sync();
    try expectFile(tmp.dir, "users.csv", "id;name;age;role\r\n1;\"a;b\";NULL;member\r\n");
}

/// A dirty `users` dataset over a file holding `original`.
fn dirtyUsers(tmp: *testing.TmpDir, original: []const u8) !WritableGateway {
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "users.csv", .data = original });
    var gw = writable(tmp.dir);
    errdefer gw.deinit();
    _ = try (try gw.dataset(Users)).insert(.{ .id = 2, .name = "Bob", .age = null });
    return gw;
}

test "a sync that cannot create the temp file leaves the original unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "id,name\n1,Ada\n";
    var gw = try dirtyUsers(&tmp, original);
    defer gw.deinit();

    // Something already at the temp path that is not a file.
    try tmp.dir.createDirPath(testing.io, "users.csv.tmp");
    try testing.expectError(error.IsDir, gw.sync());
    try testing.expectEqualStrings("users.csv: sync failed: IsDir", gw.diagnostic.message());
    try expectFile(tmp.dir, "users.csv", original);

    // Still dirty: once the obstacle is gone, the retry writes the row.
    try tmp.dir.deleteDir(testing.io, "users.csv.tmp");
    try gw.sync();
    try expectFile(tmp.dir, "users.csv", "id,name,age,role\n1,Ada,,member\n2,Bob,,member\n");
}

test "a sync into a read-only directory leaves the original unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const original = "id,name\n1,Ada\n";
    var gw = try dirtyUsers(&tmp, original);
    defer gw.deinit();

    const Perm = std.Io.File.Permissions;
    if (!@hasDecl(Perm, "fromMode")) return error.SkipZigTest;
    // Through the parent: the temp dir's own handle may not allow fchmod.
    try tmp.parent_dir.setFilePermissions(testing.io, &tmp.sub_path, .fromMode(0o555), .{});
    defer tmp.parent_dir.setFilePermissions(testing.io, &tmp.sub_path, .fromMode(0o755), .{}) catch {};

    // Root (or a file system ignoring modes) can still write: nothing to test.
    if (tmp.dir.createFile(testing.io, "probe", .{})) |f| {
        f.close(testing.io);
        return error.SkipZigTest;
    } else |_| {}

    if (gw.sync()) |_| return error.TestUnexpectedResult else |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.ReadOnlyFileSystem => {},
        else => return err,
    }
    try expectFile(tmp.dir, "users.csv", original);
    try expectNoFile(tmp.dir, "users.csv.tmp");
}

test "sync keeps the file's permissions" {
    const Perm = std.Io.File.Permissions;
    if (!@hasDecl(Perm, "fromMode")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var gw = try dirtyUsers(&tmp, "id,name\n1,Ada\n");
    defer gw.deinit();
    try tmp.dir.setFilePermissions(testing.io, "users.csv", .fromMode(0o600), .{});
    try gw.sync();
    const st = try tmp.dir.statFile(testing.io, "users.csv", .{});
    try testing.expectEqual(0o600, st.permissions.toMode() & 0o777);
}

// -- combine -----------------------------------------------------------------

const Author = struct { id: u32, name: []const u8 };
const Article = struct { id: u32, author_id: u32, title: []const u8 };
const AuthorSchema = zom.Schema(Author, "authors", .id, .{
    .associations = struct {
        pub const articles = zom.hasMany(ArticleSchema, .author_id);
    },
});
const ArticleSchema = zom.Schema(Article, "articles", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(AuthorSchema, .author_id);
    },
});

test "combine: has-many and belongs-to over two CSV files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "authors.csv", .data = "id,name\n1,Achieng\n2,Otieno\n3,Wanjiru\n" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "articles.csv",
        .data = "id,author_id,title\n10,1,Relations are values\n11,1,Mappers not models\n12,2,Comptime schemas\n13,9,Orphan\n",
    });
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    const authors = try zom.Relation(AuthorSchema, Gateway).init(&gw);
    const articles = try zom.Relation(ArticleSchema, Gateway).init(&gw);

    const Writer = struct { id: u32, name: []const u8, articles: []const struct { id: u32, title: []const u8 } };
    var writers = try authors.order(.id, .asc).combine(.articles, articles.order(.id, .asc)).mapTo(Writer, testing.allocator);
    defer writers.deinit();
    try testing.expectEqual(3, writers.items.len);
    try testing.expectEqual(2, writers.items[0].articles.len);
    try testing.expectEqualStrings("Mappers not models", writers.items[0].articles[1].title);
    try testing.expectEqual(1, writers.items[1].articles.len);
    try testing.expectEqual(0, writers.items[2].articles.len);

    const Byline = struct { title: []const u8, author: ?Author };
    var bylines = try articles.order(.id, .asc).combine(.author, authors).mapTo(Byline, testing.allocator);
    defer bylines.deinit();
    try testing.expectEqual(4, bylines.items.len);
    try testing.expectEqualStrings("Achieng", bylines.items[1].author.?.name);
    try testing.expectEqualStrings("Otieno", bylines.items[2].author.?.name);
    try testing.expect(bylines.items[3].author == null);
}

test "combine: the articles relation's limit and offset page each author's articles" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "authors.csv", .data = "id,name\n1,Achieng\n2,Otieno\n3,Wanjiru\n" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "articles.csv",
        .data = "id,author_id,title\n10,1,a\n11,1,b\n12,2,c\n13,1,d\n14,2,e\n",
    });
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    const authors = try zom.Relation(AuthorSchema, Gateway).init(&gw);
    const articles = try zom.Relation(ArticleSchema, Gateway).init(&gw);

    const Writer = struct { id: u32, articles: []const struct { id: u32 } };
    // The two latest articles of each author.
    var latest = try authors.order(.id, .asc).combine(.articles, articles.order(.id, .desc).limit(2)).mapTo(Writer, testing.allocator);
    defer latest.deinit();
    try testing.expectEqual(3, latest.items.len);
    try testing.expectEqual(2, latest.items[0].articles.len);
    try testing.expectEqual(13, latest.items[0].articles[0].id);
    try testing.expectEqual(11, latest.items[0].articles[1].id);
    try testing.expectEqual(2, latest.items[1].articles.len);
    try testing.expectEqual(14, latest.items[1].articles[0].id);
    try testing.expectEqual(12, latest.items[1].articles[1].id);
    try testing.expectEqual(0, latest.items[2].articles.len);

    // Each author's second article.
    var second = try authors.order(.id, .asc).combine(.articles, articles.order(.id, .asc).offset(1).limit(1)).mapTo(Writer, testing.allocator);
    defer second.deinit();
    try testing.expectEqual(11, second.items[0].articles[0].id);
    try testing.expectEqual(14, second.items[1].articles[0].id);
    try testing.expectEqual(0, second.items[2].articles.len);
}

// -- nested combine ----------------------------------------------------------

/// Counts the reads of each dataset, through the instrumentation hook.
const ReadCounter = struct {
    var editors: usize = 0;
    var books: usize = 0;
    var chapters: usize = 0;

    pub fn before(e: zom.plugins.instrumentation.Event) void {
        if (e.op != .read) return;
        if (std.mem.eql(u8, e.dataset, "editors")) editors += 1;
        if (std.mem.eql(u8, e.dataset, "books")) books += 1;
        if (std.mem.eql(u8, e.dataset, "chapters")) chapters += 1;
    }

    fn reset() void {
        editors = 0;
        books = 0;
        chapters = 0;
    }
};

const Editor = struct { id: u32, name: []const u8 };
const Book = struct { id: u32, editor_id: u32, title: []const u8 };
const Chapter = struct { id: u32, book_id: u32, heading: []const u8 };
const EditorSchema = zom.Schema(Editor, "editors", .id, .{
    .plugins = .{ReadCounter},
    .associations = struct {
        pub const books = zom.hasMany(BookSchema, .editor_id);
    },
});
const BookSchema = zom.Schema(Book, "books", .id, .{
    .plugins = .{ReadCounter},
    .associations = struct {
        pub const chapters = zom.hasMany(ChapterSchema, .book_id);
    },
});
const ChapterSchema = zom.Schema(Chapter, "chapters", .id, .{ .plugins = .{ReadCounter} });

test "nested combine: editors -> books -> chapters over three CSV files, one read per level" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "editors.csv", .data = "id,name\n1,Achieng\n2,Otieno\n" });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "books.csv",
        .data = "id,editor_id,title\n10,1,Relations\n11,1,Mappers\n12,2,Comptime\n",
    });
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "chapters.csv",
        .data = "id,book_id,heading\n100,10,Values\n101,10,Filters\n102,12,Types\n103,99,Orphan\n",
    });
    var gw = Gateway.init(testing.allocator, .{ .io = testing.io, .dir = tmp.dir, .path = "." });
    defer gw.deinit();
    const editors = try zom.Relation(EditorSchema, Gateway).init(&gw);
    const books = try zom.Relation(BookSchema, Gateway).init(&gw);
    const chapters = try zom.Relation(ChapterSchema, Gateway).init(&gw);

    const Shelf = struct {
        name: []const u8,
        books: []const struct { title: []const u8, chapters: []const struct { heading: []const u8 } },
    };
    ReadCounter.reset();
    var shelves = try editors.order(.id, .asc)
        .combine(.books, books.order(.id, .asc).combine(.chapters, chapters.order(.id, .asc)))
        .mapTo(Shelf, testing.allocator);
    defer shelves.deinit();

    try testing.expectEqual(1, ReadCounter.editors);
    try testing.expectEqual(1, ReadCounter.books);
    try testing.expectEqual(1, ReadCounter.chapters);
    const s = shelves.items;
    try testing.expectEqual(2, s.len);
    try testing.expectEqual(2, s[0].books.len);
    try testing.expectEqual(2, s[0].books[0].chapters.len);
    try testing.expectEqualStrings("Filters", s[0].books[0].chapters[1].heading);
    try testing.expectEqual(0, s[0].books[1].chapters.len);
    try testing.expectEqual(1, s[1].books.len);
    try testing.expectEqualStrings("Types", s[1].books[0].chapters[0].heading);
}
