const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const zom = @import("zom");
const root = @import("root.zig");
const Gateway = root.Gateway;

// -- zom.lint ----------------------------------------------------------------

/// Each lint check gets a fresh temp directory, seeded with one CSV file per
/// schema through `writeTable`. Checks run one at a time, so one slot is
/// enough.
const LintFactory = struct {
    var tmp: ?testing.TmpDir = null;

    pub fn create(allocator: Allocator) !Gateway {
        std.debug.assert(tmp == null);
        tmp = testing.tmpDir(.{});
        return Gateway.init(allocator, .{ .io = testing.io, .dir = tmp.?.dir, .path = "." });
    }

    pub fn destroy(g: *Gateway) void {
        g.deinit();
        tmp.?.cleanup();
        tmp = null;
    }

    pub fn seed(g: *Gateway, comptime S: type, rows: []const S.Tuple) !void {
        try writeFixture(g.config.dir, S.name ++ ".csv", S.Tuple, rows);
    }
};

fn writeFixture(dir: std.Io.Dir, name: []const u8, comptime T: type, rows: []const T) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try root.writeTable(&out.writer, T, rows, testing.allocator, .{});
    try dir.writeFile(testing.io, .{ .sub_path = name, .data = out.written() });
}

test "zom.lint: read checks pass, write checks are skipped" {
    try testing.expect(zom.Adapter(Gateway).readOnly(zom.lint.Users));
    try zom.lint.run(Gateway, LintFactory);
}

// -- loading -----------------------------------------------------------------

const Role = enum { admin, member };
const User = struct {
    id: u32,
    name: []const u8,
    age: ?u8,
    role: Role = .member,
};
const Users = zom.Schema(User, "users", .id);

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

    const Posts = zom.Schema(struct { id: u32 }, "posts", .id);
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
