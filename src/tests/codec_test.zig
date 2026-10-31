//! zom.codec: table-driven decodeField cases per type, then decodeRow and
//! its Diagnostic.

const std = @import("std");
const zom = @import("../root.zig");
const codec = zom.codec;
const testing = std.testing;
const DecodeError = codec.DecodeError;

fn Case(comptime T: type) type {
    return struct { in: []const u8, want: DecodeError!T };
}

fn expectCases(comptime T: type, cases: []const Case(T), opts: codec.Options) !void {
    for (cases) |c| {
        const got = codec.decodeField(T, c.in, opts);
        errdefer std.debug.print("decodeField({s}, \"{s}\"): got {any}, want {any}\n", .{ @typeName(T), c.in, got, c.want });
        if (c.want) |want| {
            if (comptime T == []const u8) try testing.expectEqualStrings(want, try got) else try testing.expectEqual(want, try got);
        } else |want_err| {
            try testing.expectError(want_err, got);
        }
    }
}

test "integers" {
    try expectCases(u8, &.{
        .{ .in = "0", .want = 0 },
        .{ .in = "255", .want = 255 },
        .{ .in = "+7", .want = 7 },
        .{ .in = "-0", .want = 0 },
        .{ .in = "1_0", .want = 10 },
        .{ .in = "256", .want = error.ValueOutOfRange },
        .{ .in = "-1", .want = error.ValueOutOfRange },
        .{ .in = "abc", .want = error.InvalidInt },
        .{ .in = " 5", .want = error.InvalidInt },
        .{ .in = "5 ", .want = error.InvalidInt },
        .{ .in = "0x10", .want = error.InvalidInt },
        .{ .in = "1.5", .want = error.InvalidInt },
        .{ .in = "-", .want = error.InvalidInt },
        .{ .in = "", .want = error.UnexpectedNull },
    }, .{});
    try expectCases(i64, &.{
        .{ .in = "-0", .want = 0 },
        .{ .in = "-9223372036854775808", .want = std.math.minInt(i64) },
        .{ .in = "9223372036854775808", .want = error.ValueOutOfRange },
    }, .{});
}

test "floats" {
    try expectCases(f64, &.{
        .{ .in = "1.5", .want = 1.5 },
        .{ .in = "-0", .want = -0.0 },
        .{ .in = "1e3", .want = 1000 },
        .{ .in = "7", .want = 7 },
        .{ .in = "inf", .want = std.math.inf(f64) },
        .{ .in = "abc", .want = error.InvalidFloat },
        .{ .in = " 1.5", .want = error.InvalidFloat },
        .{ .in = "1,5", .want = error.InvalidFloat },
        .{ .in = "", .want = error.UnexpectedNull },
    }, .{});
    // -0.0 == 0.0, so check the sign separately.
    try testing.expect(std.math.signbit(try codec.decodeField(f64, "-0", .{})));
}

test "bools" {
    try expectCases(bool, &.{
        .{ .in = "true", .want = true },
        .{ .in = "TRUE", .want = true },
        .{ .in = "t", .want = true },
        .{ .in = "T", .want = true },
        .{ .in = "1", .want = true },
        .{ .in = "false", .want = false },
        .{ .in = "False", .want = false },
        .{ .in = "f", .want = false },
        .{ .in = "0", .want = false },
        .{ .in = "yes", .want = error.InvalidBool },
        .{ .in = "2", .want = error.InvalidBool },
        .{ .in = " true", .want = error.InvalidBool },
        .{ .in = "", .want = error.UnexpectedNull },
    }, .{});
}

const Role = enum { admin, member };

test "enums" {
    try expectCases(Role, &.{
        .{ .in = "admin", .want = .admin },
        .{ .in = "member", .want = .member },
        .{ .in = "Admin", .want = error.InvalidEnum },
        .{ .in = "guest", .want = error.InvalidEnum },
        .{ .in = "", .want = error.UnexpectedNull },
    }, .{});
}

test "strings borrow the text, and keep empty and padded values" {
    try expectCases([]const u8, &.{
        .{ .in = "Ada", .want = "Ada" },
        .{ .in = " Ada ", .want = " Ada " },
        .{ .in = "", .want = "" },
    }, .{});
    const text: []const u8 = "Ada";
    const got = try codec.decodeField([]const u8, text, .{});
    try testing.expectEqual(text.ptr, got.ptr);
}

test "optionals: null_text is null, anything else decodes the child" {
    try expectCases(?u8, &.{
        .{ .in = "", .want = null },
        .{ .in = "5", .want = 5 },
        .{ .in = "256", .want = error.ValueOutOfRange },
        .{ .in = "abc", .want = error.InvalidInt },
    }, .{});
    try expectCases(?bool, &.{
        .{ .in = "NULL", .want = null },
        .{ .in = "t", .want = true },
        .{ .in = "", .want = error.InvalidBool },
    }, .{ .null_text = "NULL" });
    try testing.expectEqual(@as(?[]const u8, null), try codec.decodeField(?[]const u8, "", .{}));
    try testing.expectEqualStrings("x", (try codec.decodeField(?[]const u8, "x", .{})).?);
}

test "null_text = null turns null detection off" {
    try expectCases(u8, &.{.{ .in = "", .want = error.InvalidInt }}, .{ .null_text = null });
    try expectCases(?u8, &.{.{ .in = "", .want = error.InvalidInt }}, .{ .null_text = null });
    try expectCases(u8, &.{.{ .in = "NULL", .want = error.UnexpectedNull }}, .{ .null_text = "NULL" });
}

const User = struct {
    id: u32,
    name: []const u8,
    age: u8,
    role: Role,
    active: bool = true,
    score: ?f64,
};

test "decodeRow in field order" {
    const u = try codec.decodeRow(User, &.{ "1", "Ada", "36", "admin", "f", "" }, .{}, null);
    try testing.expectEqual(1, u.id);
    try testing.expectEqualStrings("Ada", u.name);
    try testing.expectEqual(36, u.age);
    try testing.expectEqual(Role.admin, u.role);
    try testing.expectEqual(false, u.active);
    try testing.expectEqual(null, u.score);
}

test "decodeRow: missing cells use the default, then null, else MissingField" {
    // `active` has a default and `score` is optional, so a 4-cell row is enough.
    const u = try codec.decodeRow(User, &.{ "1", "Ada", "36", "admin" }, .{}, null);
    try testing.expectEqual(true, u.active);
    try testing.expectEqual(null, u.score);

    var diag: codec.Diagnostic = .{};
    try testing.expectError(error.MissingField, codec.decodeRow(User, &.{ "1", "Ada", "36" }, .{ .row = 2 }, &diag));
    try testing.expectEqual(2, diag.row);
    try testing.expectEqual(4, diag.column);
    try testing.expectEqualStrings("role", diag.field);
}

test "decodeRow with a column map" {
    // Header order: name, score, id, role, age. No `active` column.
    const columns = [_]?usize{ 2, 0, 4, 3, null, 1 };
    const u = try codec.decodeRow(User, &.{ "Ada", "9.5", "1", "member", "36" }, .{ .columns = &columns }, null);
    try testing.expectEqual(1, u.id);
    try testing.expectEqualStrings("Ada", u.name);
    try testing.expectEqual(36, u.age);
    try testing.expectEqual(Role.member, u.role);
    try testing.expectEqual(true, u.active);
    try testing.expectEqual(9.5, u.score.?);

    const no_role = [_]?usize{ 2, 0, 4, null, null, 1 };
    var diag: codec.Diagnostic = .{};
    try testing.expectError(error.MissingField, codec.decodeRow(User, &.{ "Ada", "9.5", "1", "member", "36" }, .{ .columns = &no_role, .row = 7 }, &diag));
    try testing.expectEqual(0, diag.column);
    try testing.expectEqualStrings("role", diag.field);
}

test "Diagnostic names the row, column, field and text" {
    var diag: codec.Diagnostic = .{};
    const cells = [_][]const u8{ "1", "Ada", "abc", "admin" };
    try testing.expectError(error.InvalidInt, codec.decodeRow(User, &cells, .{ .row = 14 }, &diag));
    try testing.expectEqual(14, diag.row);
    try testing.expectEqual(3, diag.column);
    try testing.expectEqualStrings("age", diag.field);
    try testing.expectEqualStrings("abc", diag.text);
    try testing.expectEqual(error.InvalidInt, diag.err.?);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "users.csv:14:3 (age): \"abc\" is not an integer from 0 to 255",
        try std.fmt.bufPrint(&buf, "users.csv:{f}", .{diag}),
    );
}

test "Diagnostic messages per error" {
    const Want = struct { cells: []const []const u8, msg: []const u8 };
    const cases = [_]Want{
        .{ .cells = &.{ "1", "Ada", "256", "admin" }, .msg = "1:3 (age): \"256\" is out of range, expected an integer from 0 to 255" },
        .{ .cells = &.{ "1", "Ada", "", "admin" }, .msg = "1:3 (age): empty, but the field is not optional" },
        .{ .cells = &.{ "1", "Ada", "3", "guest" }, .msg = "1:4 (role): \"guest\" is not one of: admin, member" },
        .{ .cells = &.{ "1", "Ada", "3", "admin", "yes" }, .msg = "1:5 (active): \"yes\" is not a boolean (true, false, 1, 0, t, f)" },
        .{ .cells = &.{ "1", "Ada", "3", "admin", "t", "x" }, .msg = "1:6 (score): \"x\" is not a number" },
        .{ .cells = &.{"1"}, .msg = "1:2 (name): missing value" },
    };
    for (cases) |c| {
        var diag: codec.Diagnostic = .{};
        _ = codec.decodeRow(User, c.cells, .{ .row = 1 }, &diag) catch {};
        var buf: [128]u8 = undefined;
        try testing.expectEqualStrings(c.msg, try std.fmt.bufPrint(&buf, "{f}", .{diag}));
    }
}
