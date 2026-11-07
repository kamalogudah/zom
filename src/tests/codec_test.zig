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
    try expectCases(u128, &.{
        .{ .in = "0", .want = 0 },
        .{ .in = "18446744073709551616", .want = std.math.maxInt(u64) + 1 },
        .{ .in = "340282366920938463463374607431768211455", .want = std.math.maxInt(u128) },
        .{ .in = "340282366920938463463374607431768211456", .want = error.ValueOutOfRange },
        .{ .in = "-1", .want = error.ValueOutOfRange },
        .{ .in = "1e3", .want = error.InvalidInt },
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

// Encoding.

fn encodeAlloc(value: anytype, opts: codec.Options) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try codec.encodeField(&out.writer, value, opts);
    return out.toOwnedSlice();
}

fn expectEncoded(want: []const u8, value: anytype, opts: codec.Options) !void {
    const got = try encodeAlloc(value, opts);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "encodeField per type" {
    try expectEncoded("0", @as(u8, 0), .{});
    try expectEncoded("-9223372036854775808", @as(i64, std.math.minInt(i64)), .{});
    try expectEncoded("42", 42, .{});
    try expectEncoded("340282366920938463463374607431768211455", @as(u128, std.math.maxInt(u128)), .{});
    try expectEncoded("18446744073709551616", @as(?u128, std.math.maxInt(u64) + 1), .{});
    try expectEncoded("true", true, .{});
    try expectEncoded("false", false, .{});
    try expectEncoded("member", Role.member, .{});
    try expectEncoded(" Ada ", @as([]const u8, " Ada "), .{});
    try expectEncoded("a,b", "a,b", .{}); // no quoting: that's the CSV writer's job
    try expectEncoded("", @as(?u8, null), .{});
    try expectEncoded("NULL", @as(?u8, null), .{ .null_text = "NULL" });
    try expectEncoded("7", @as(?u8, 7), .{ .null_text = "NULL" });
    try testing.expectError(error.NullNotRepresentable, encodeAlloc(@as(?u8, null), .{ .null_text = null }));
}

test "encodeField floats: decimal for everyday magnitudes, scientific outside" {
    const cases = [_]struct { f64, []const u8 }{
        .{ 0.1, "0.1" },
        .{ 1.5, "1.5" },
        .{ 100, "100" },
        .{ 0, "0" },
        .{ -0.0, "-0" },
        .{ 1e-6, "0.000001" },
        .{ 1e20, "100000000000000000000" },
        .{ 1e21, "1e21" },
        .{ 1e-7, "1e-7" },
        .{ 1e300, "1e300" },
        .{ 5e-324, "5e-324" },
        .{ std.math.inf(f64), "inf" },
        .{ -std.math.inf(f64), "-inf" },
        .{ std.math.nan(f64), "nan" },
    };
    for (cases) |c| try expectEncoded(c[1], c[0], .{});
    // Shortest for the field's own type, not for f64.
    try expectEncoded("0.1", @as(f32, 0.1), .{});
    try expectEncoded("1e4000", @as(f128, 1e4000), .{});
}

/// Field-by-field equality: strings by content, floats by bits (so -0 and
/// nan compare as themselves).
fn expectRowEqual(comptime T: type, want: T, got: T) !void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, F| {
        const w = @field(want, name);
        const g = @field(got, name);
        errdefer std.debug.print("field {s}: want {any}, got {any}\n", .{ name, w, g });
        switch (@typeInfo(F)) {
            .optional => |o| {
                try testing.expectEqual(w == null, g == null);
                if (w) |wv| try expectValueEqual(o.child, wv, g.?);
            },
            else => try expectValueEqual(F, w, g),
        }
    }
}

fn expectValueEqual(comptime F: type, want: F, got: F) !void {
    if (F == []const u8) return testing.expectEqualStrings(want, got);
    if (@typeInfo(F) == .float) {
        const Bits = @Int(.unsigned, @bitSizeOf(F));
        return testing.expectEqual(@as(Bits, @bitCast(want)), @as(Bits, @bitCast(got)));
    }
    return testing.expectEqual(want, got);
}

fn roundTrip(comptime T: type, row: T, opts: codec.Options, sep: []const u8) !void {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try codec.encodeRow(&out.writer, T, row, opts, sep);

    var cells: [@typeInfo(T).@"struct".field_names.len][]const u8 = undefined;
    var it = std.mem.splitSequence(u8, out.written(), sep);
    var n: usize = 0;
    while (it.next()) |cell| : (n += 1) cells[n] = cell;
    try testing.expectEqual(cells.len, n);

    errdefer std.debug.print("encoded: \"{s}\"\n", .{out.written()});
    try expectRowEqual(T, row, try codec.decodeRow(T, &cells, opts, null));
}

const Reading = struct {
    id: u64,
    delta: i16,
    name: []const u8,
    role: Role,
    ok: bool,
    value: f64,
    small: f32,
    note: ?[]const u8,
    limit: ?f64,
    rank: ?u8,
};

test "encodeRow then decodeRow gives back the row" {
    const rows = [_]Reading{
        .{ .id = 1, .delta = -3, .name = "Ada", .role = .admin, .ok = true, .value = 0.1, .small = 0.1, .note = "x", .limit = 1e300, .rank = 0 },
        .{ .id = std.math.maxInt(u64), .delta = std.math.minInt(i16), .name = "", .role = .member, .ok = false, .value = 1e300, .small = std.math.floatMax(f32), .note = null, .limit = null, .rank = null },
        .{ .id = 0, .delta = 0, .name = " padded ", .role = .admin, .ok = true, .value = -0.0, .small = std.math.floatTrueMin(f32), .note = "NULLish", .limit = 5e-324, .rank = 255 },
        .{ .id = 2, .delta = 1, .name = "Grace", .role = .member, .ok = false, .value = 1e-7, .small = -1.5, .note = null, .limit = -std.math.inf(f64), .rank = 9 },
        .{ .id = 3, .delta = 2, .name = "π", .role = .admin, .ok = true, .value = 1.0 / 3.0, .small = 1e21, .note = "", .limit = 0.30000000000000004, .rank = null },
    };
    for (rows, 0..) |row, i| {
        errdefer std.debug.print("row {d}\n", .{i});
        // Row 4's note is "", which reads back as null under the default
        // null_text, so that row uses "NULL" instead.
        if (i != 4) try roundTrip(Reading, row, .{}, ",");
        try roundTrip(Reading, row, .{ .null_text = "NULL" }, "\t");
    }
}

fn expectFloatRoundTrip(comptime F: type, x: F) !void {
    if (std.math.isNan(x)) return;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try codec.encodeField(&w, x, .{});
    const back = try codec.decodeField(F, w.buffered(), .{});
    errdefer std.debug.print("{s}: \"{s}\"\n", .{ @typeName(F), w.buffered() });
    const Bits = @Int(.unsigned, @bitSizeOf(F));
    try testing.expectEqual(@as(Bits, @bitCast(x)), @as(Bits, @bitCast(back)));
}

test "floats round-trip across the whole range" {
    // Every f16, then random bit patterns (subnormals, huge exponents and
    // all) for f32 and f64. f128 is left to the fixed cases above: parsing
    // its extreme exponents in Debug takes ~70ms a value.
    for (0..1 << 16) |bits| try expectFloatRoundTrip(f16, @bitCast(@as(u16, @intCast(bits))));
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const r = prng.random();
    for (0..20_000) |_| {
        try expectFloatRoundTrip(f32, @bitCast(r.int(u32)));
        try expectFloatRoundTrip(f64, @bitCast(r.int(u64)));
    }
    try testing.expect(std.math.isNan(try codec.decodeField(f64, "nan", .{})));
}
