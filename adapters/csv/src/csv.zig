//! RFC 4180 CSV text: `Reader` splits a whole file into rows of cells, and
//! `writeRow` writes one row back. Nothing here knows about zom; the gateway
//! reads the header (just the first row) and decodes cells with `zom.codec`.
//!
//! Format:
//!
//! - Cells are separated by `Options.separator` (`,` by default). Records end
//!   with `\n` or `\r\n`. A lone `\r` outside quotes is ordinary data.
//! - A final line break is optional: `a,b` and `a,b\n` are both one row.
//! - A quoted cell (`"a, b"`) may hold the separator, line breaks, and quotes
//!   written twice (`"say ""hi"""` is `say "hi"`). The quote must open the
//!   cell and the closing quote must be followed by a separator or line end.
//! - A blank line is a row with zero cells. `writeRow` writes a row with one
//!   empty cell as `""`, so both shapes survive a round-trip.
//! - No whitespace is trimmed, and an empty cell (`a,,b`) is `""`.
//!
//! Memory: the reader borrows `input` and allocates as little as it can.
//! A cell without `""` escapes is a sub-slice of `input`. A cell with them is
//! unescaped into an arena the reader owns, which is reset on every `next()`.
//! The row's slice of cells lives in a fixed buffer inside the reader (an
//! allocated list only for rows wider than `inline_cells`). So a row of up to
//! `inline_cells` cells with no escapes costs no allocation at all.
//!
//! Lifetimes: a row and every cell in it are valid until the next call to
//! `next()` or `deinit()`, whichever comes first; copy what you keep. (Cells
//! without escapes happen to live as long as `input`, but don't rely on it.)
//! The `Reader` must not be moved while a row it returned is in use, since
//! the row may point into the reader itself.

const std = @import("std");

pub const Options = struct {
    /// Must not be `"`, `\r` or `\n`.
    separator: u8 = ',',
    /// `writeRow` only: written after every row. RFC 4180 uses `"\r\n"`;
    /// the default keeps files diff-friendly. The reader accepts both.
    line_ending: []const u8 = "\n",
};

pub const Error = error{
    /// A quoted cell has no closing quote before the end of the input.
    /// `Diagnostic` points at the opening quote.
    UnterminatedQuote,
    /// A quote inside an unquoted cell (`a"b`), or a closing quote followed by
    /// something other than a separator or line end (`"a"b`). `Diagnostic`
    /// points at the quote.
    UnexpectedQuote,
} || std.mem.Allocator.Error;

/// Where a read failed. Zig errors carry no data, so the reader fills this in
/// (see `Reader.diagnostic`). Formatted with `{f}` it reads
/// `3:7: unterminated quote`; the gateway prefixes the file name.
pub const Diagnostic = struct {
    /// 1-based physical line: line breaks inside quoted cells count.
    line: usize = 0,
    /// 1-based byte column within that line.
    column: usize = 0,
    err: ?Error = null,

    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: ", .{ d.line, d.column });
        const err = d.err orelse return w.writeAll("no error");
        try w.writeAll(switch (err) {
            error.UnterminatedQuote => "unterminated quote",
            error.UnexpectedQuote => "unexpected quote (a quote must open a cell, be doubled inside one, or close it before a separator or line end)",
            error.OutOfMemory => "out of memory",
        });
    }
};

/// One record. See the module comment for how long it stays valid.
pub const Row = []const []const u8;

pub const Reader = struct {
    /// Rows up to this many cells need no allocation for the cell list.
    pub const inline_cells = 64;

    input: []const u8,
    options: Options,
    /// Set this to get positions for errors. Filled in only when `next()`
    /// returns `UnterminatedQuote` or `UnexpectedQuote`.
    diagnostic: ?*Diagnostic = null,
    /// The 1-based line on which the row last returned by `next()` starts.
    /// The gateway passes it to `zom.codec.Options.row`.
    row_line: usize = 0,

    allocator: std.mem.Allocator,
    pos: usize = 0,
    line: usize = 1,
    line_start: usize = 0,
    /// Unescaped cells of the current row.
    scratch: std.heap.ArenaAllocator,
    inline_buf: [inline_cells][]const u8 = undefined,
    inline_len: usize = 0,
    /// Used instead of `inline_buf` once a row outgrows it; reused across rows.
    overflow: std.ArrayList([]const u8) = .empty,
    overflowed: bool = false,

    const State = enum { field_start, in_unquoted, in_quoted, quote_in_quoted };

    /// `allocator` is used only for cells with `""` escapes and for rows wider
    /// than `inline_cells`. `input` must outlive the reader.
    pub fn init(allocator: std.mem.Allocator, input: []const u8, options: Options) Reader {
        std.debug.assert(switch (options.separator) {
            '"', '\r', '\n' => false,
            else => true,
        });
        return .{
            .input = input,
            .options = options,
            .allocator = allocator,
            .scratch = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Reader) void {
        self.scratch.deinit();
        self.overflow.deinit(self.allocator);
        self.* = undefined;
    }

    /// The next row, or `null` at the end of the input. After an error the
    /// reader is finished and returns `null`.
    pub fn next(self: *Reader) Error!?Row {
        return self.parseRow() catch |err| {
            self.pos = self.input.len;
            return err;
        };
    }

    fn parseRow(self: *Reader) Error!?Row {
        const input = self.input;
        if (self.pos >= input.len) return null;

        _ = self.scratch.reset(.retain_capacity);
        self.inline_len = 0;
        self.overflow.clearRetainingCapacity();
        self.overflowed = false;
        self.row_line = self.line;

        // A blank line is a row of zero cells.
        if (self.lineBreakAt(self.pos)) |len| {
            self.endLine(self.pos + len);
            return self.row();
        }

        const sep = self.options.separator;
        const specials = [_]u8{ sep, '"', '\n' };
        // Start of the current cell's content (after the opening quote, if any).
        var start: usize = self.pos;
        // Offset of the opening quote, for `UnterminatedQuote`.
        var open_quote: usize = 0;
        var open_line: usize = 0;
        var open_line_start: usize = 0;
        var escaped = false;

        state: switch (State.field_start) {
            .field_start => {
                // The input ended right after a separator: one more empty cell.
                if (self.pos == input.len) {
                    try self.push("");
                    return self.row();
                }
                if (input[self.pos] == '"') {
                    open_quote = self.pos;
                    open_line = self.line;
                    open_line_start = self.line_start;
                    escaped = false;
                    self.pos += 1;
                    start = self.pos;
                    continue :state .in_quoted;
                }
                start = self.pos;
                continue :state .in_unquoted;
            },
            .in_unquoted => {
                const i = std.mem.indexOfAnyPos(u8, input, self.pos, &specials) orelse {
                    self.pos = input.len;
                    try self.push(input[start..]);
                    return self.row();
                };
                self.pos = i;
                const c = input[i];
                if (c == '"') return self.fail(error.UnexpectedQuote, i, self.line, self.line_start);
                if (c == '\n') {
                    // `\r\n`: the `\r` belongs to the line break, not the cell.
                    const end = if (i > start and input[i - 1] == '\r') i - 1 else i;
                    try self.push(input[start..end]);
                    self.endLine(i + 1);
                    return self.row();
                }
                try self.push(input[start..i]); // separator
                self.pos = i + 1;
                continue :state .field_start;
            },
            .in_quoted => {
                const i = std.mem.indexOfScalarPos(u8, input, self.pos, '"') orelse
                    return self.fail(error.UnterminatedQuote, open_quote, open_line, open_line_start);
                self.countLines(self.pos, i);
                self.pos = i + 1;
                continue :state .quote_in_quoted;
            },
            .quote_in_quoted => {
                const quote = self.pos - 1;
                if (self.pos == input.len) {
                    try self.pushQuoted(input[start..quote], escaped);
                    return self.row();
                }
                const c = input[self.pos];
                if (c == '"') {
                    escaped = true;
                    self.pos += 1;
                    continue :state .in_quoted;
                }
                if (c == sep) {
                    try self.pushQuoted(input[start..quote], escaped);
                    self.pos += 1;
                    continue :state .field_start;
                }
                if (self.lineBreakAt(self.pos)) |len| {
                    try self.pushQuoted(input[start..quote], escaped);
                    self.endLine(self.pos + len);
                    return self.row();
                }
                return self.fail(error.UnexpectedQuote, quote, self.line, self.line_start);
            },
        }
    }

    /// The length of the line break at `i` (1 for `\n`, 2 for `\r\n`), or null.
    fn lineBreakAt(self: *const Reader, i: usize) ?usize {
        const input = self.input;
        if (input[i] == '\n') return 1;
        if (input[i] == '\r' and i + 1 < input.len and input[i + 1] == '\n') return 2;
        return null;
    }

    /// Moves past a line break that ends just before `after`.
    fn endLine(self: *Reader, after: usize) void {
        self.pos = after;
        self.line += 1;
        self.line_start = after;
    }

    /// Advances the line count over the `\n`s in `input[from..to]`.
    fn countLines(self: *Reader, from: usize, to: usize) void {
        var i = from;
        while (std.mem.indexOfScalarPos(u8, self.input[0..to], i, '\n')) |nl| {
            self.line += 1;
            self.line_start = nl + 1;
            i = nl + 1;
        }
    }

    fn fail(self: *Reader, err: Error, at: usize, line: usize, line_start: usize) Error {
        if (self.diagnostic) |d| d.* = .{ .line = line, .column = at - line_start + 1, .err = err };
        return err;
    }

    fn pushQuoted(self: *Reader, raw: []const u8, escaped: bool) Error!void {
        if (!escaped) return self.push(raw);
        // Every `""` becomes `"`, so the result is never longer than `raw`.
        const buf = try self.scratch.allocator().alloc(u8, raw.len);
        var n: usize = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            buf[n] = raw[i];
            n += 1;
            if (raw[i] == '"') i += 1; // skip the second quote of the pair
        }
        try self.push(buf[0..n]);
    }

    fn push(self: *Reader, cell: []const u8) Error!void {
        if (!self.overflowed) {
            if (self.inline_len < inline_cells) {
                self.inline_buf[self.inline_len] = cell;
                self.inline_len += 1;
                return;
            }
            try self.overflow.appendSlice(self.allocator, &self.inline_buf);
            self.overflowed = true;
        }
        try self.overflow.append(self.allocator, cell);
    }

    fn row(self: *const Reader) Row {
        return if (self.overflowed) self.overflow.items else self.inline_buf[0..self.inline_len];
    }
};

/// Writes `cells` as one record followed by `options.line_ending`. A cell is
/// quoted only when it holds the separator, `"`, `\r` or `\n` (inner quotes
/// are doubled), or when it is the only cell and is empty, so that the line
/// doesn't read back as a blank (zero-cell) row.
pub fn writeRow(writer: *std.Io.Writer, cells: []const []const u8, options: Options) std.Io.Writer.Error!void {
    const specials = [_]u8{ options.separator, '"', '\r', '\n' };
    for (cells, 0..) |cell, i| {
        if (i != 0) try writer.writeByte(options.separator);
        const quote = std.mem.indexOfAny(u8, cell, &specials) != null or
            (cells.len == 1 and cell.len == 0);
        if (!quote) {
            try writer.writeAll(cell);
            continue;
        }
        try writer.writeByte('"');
        var it = std.mem.splitScalar(u8, cell, '"');
        try writer.writeAll(it.first());
        while (it.next()) |part| {
            try writer.writeAll("\"\"");
            try writer.writeAll(part);
        }
        try writer.writeByte('"');
    }
    try writer.writeAll(options.line_ending);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// Reads all of `input` and checks it against `expected`.
fn expectRows(input: []const u8, options: Options, expected: []const []const []const u8) !void {
    var r = Reader.init(testing.allocator, input, options);
    defer r.deinit();
    var n: usize = 0;
    while (try r.next()) |row| : (n += 1) {
        if (n >= expected.len) {
            std.debug.print("unexpected extra row {d}: {any}\n", .{ n, row });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(expected[n].len, row.len);
        for (expected[n], row) |want, got| try testing.expectEqualStrings(want, got);
    }
    try testing.expectEqual(expected.len, n);
}

fn expectError(input: []const u8, err: Error, line: usize, column: usize) !void {
    var diag: Diagnostic = .{};
    var r = Reader.init(testing.allocator, input, .{});
    defer r.deinit();
    r.diagnostic = &diag;
    const result = while (true) {
        _ = (r.next() catch |e| break e) orelse return error.TestExpectedError;
    };
    try testing.expectEqual(err, result);
    try testing.expectEqual(Diagnostic{ .line = line, .column = column, .err = err }, diag);
    try testing.expectEqual(null, try r.next());
}

test "empty input has no rows" {
    try expectRows("", .{}, &.{});
}

test "a trailing line break is optional" {
    try expectRows("a,b\nc,d", .{}, &.{ &.{ "a", "b" }, &.{ "c", "d" } });
    try expectRows("a,b\nc,d\n", .{}, &.{ &.{ "a", "b" }, &.{ "c", "d" } });
}

test "blank lines are rows with no cells" {
    try expectRows("\n", .{}, &.{&.{}});
    try expectRows("a\n\nb\n\n", .{}, &.{ &.{"a"}, &.{}, &.{"b"}, &.{} });
    try expectRows("a\r\n\r\nb", .{}, &.{ &.{"a"}, &.{}, &.{"b"} });
}

test "empty cells" {
    try expectRows("a,,b\n", .{}, &.{&.{ "a", "", "b" }});
    try expectRows(",\n", .{}, &.{&.{ "", "" }});
    try expectRows("a,", .{}, &.{&.{ "a", "" }});
    try expectRows("\"\",x", .{}, &.{&.{ "", "x" }});
}

test "quoted cells hold separators, line breaks and doubled quotes" {
    try expectRows(
        "id,text\n1,\"a, b\"\n2,\"line one\nline two\"\n3,\"say \"\"hi\"\"\"\n4,\"\"\"\"\n",
        .{},
        &.{
            &.{ "id", "text" },
            &.{ "1", "a, b" },
            &.{ "2", "line one\nline two" },
            &.{ "3", "say \"hi\"" },
            &.{ "4", "\"" },
        },
    );
    try expectRows("\"a\r\nb\"\r\n", .{}, &.{&.{"a\r\nb"}});
}

test "CRLF line endings" {
    try expectRows("a,b\r\nc,\"d\"\r\n,\r\n", .{}, &.{ &.{ "a", "b" }, &.{ "c", "d" }, &.{ "", "" } });
    // A lone \r is data.
    try expectRows("a\rb,c\r", .{}, &.{&.{ "a\rb", "c\r" }});
}

test "whitespace is kept" {
    try expectRows(" a , b \n", .{}, &.{&.{ " a ", " b " }});
}

test "a custom separator" {
    try expectRows("a;b,c;\"x;y\"\n", .{ .separator = ';' }, &.{&.{ "a", "b,c", "x;y" }});
    try expectRows("a\tb\n", .{ .separator = '\t' }, &.{&.{ "a", "b" }});
}

test "rows wider than the inline buffer" {
    const width = Reader.inline_cells * 2 + 3;
    var text: std.Io.Writer.Allocating = .init(testing.allocator);
    defer text.deinit();
    for (0..2) |_| {
        for (0..width) |i| {
            if (i != 0) try text.writer.writeByte(',');
            try text.writer.print("c{d}", .{i});
        }
        try text.writer.writeByte('\n');
    }
    var r = Reader.init(testing.allocator, text.written(), .{});
    defer r.deinit();
    var rows: usize = 0;
    while (try r.next()) |row| : (rows += 1) {
        try testing.expectEqual(width, row.len);
        try testing.expectEqualStrings("c0", row[0]);
        try testing.expectEqualStrings(std.fmt.comptimePrint("c{d}", .{width - 1}), row[width - 1]);
    }
    try testing.expectEqual(2, rows);
}

test "row_line is the line a row starts on" {
    var r = Reader.init(testing.allocator, "a\n\"b\nc\"\r\nd", .{});
    defer r.deinit();
    _ = try r.next();
    try testing.expectEqual(1, r.row_line);
    _ = try r.next();
    try testing.expectEqual(2, r.row_line);
    _ = try r.next();
    try testing.expectEqual(4, r.row_line);
    try testing.expectEqual(null, try r.next());
}

test "an unterminated quote points at the opening quote" {
    try expectError("a,b\nc,\"d\ne\n", error.UnterminatedQuote, 2, 3);
    try expectError("\"", error.UnterminatedQuote, 1, 1);
    // A doubled quote at the very end doesn't close the cell.
    try expectError("\"a\"\"", error.UnterminatedQuote, 1, 1);
}

test "an unexpected quote points at the quote" {
    try expectError("ok\na\"b\n", error.UnexpectedQuote, 2, 2);
    try expectError("x,\"a\nb\"c\n", error.UnexpectedQuote, 2, 2);
    try expectError("\"a\" ,b", error.UnexpectedQuote, 1, 3);
}

test "Diagnostic formats as line:column: message" {
    const d: Diagnostic = .{ .line = 3, .column = 7, .err = error.UnterminatedQuote };
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("3:7: unterminated quote", try std.fmt.bufPrint(&buf, "{f}", .{d}));
}

test "rows without escapes make no allocations" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var r = Reader.init(failing.allocator(), "id,name\n1,\"Ada, Countess\"\r\n2,\"multi\nline\"\n\n3,,\n", .{});
    defer r.deinit();
    var rows: usize = 0;
    while (try r.next()) |_| rows += 1;
    try testing.expectEqual(5, rows);
    try testing.expectEqual(0, failing.allocations);

    // An escape needs the allocator, and the failure is reported.
    var r2 = Reader.init(failing.allocator(), "\"a\"\"b\"", .{});
    defer r2.deinit();
    try testing.expectError(error.OutOfMemory, r2.next());
}

test "writeRow quotes only when needed" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeRow(&w, &.{ "plain", "a,b", "say \"hi\"", "two\nlines", "cr\r", "", " pad " }, .{});
    try writeRow(&w, &.{""}, .{});
    try writeRow(&w, &.{}, .{});
    try writeRow(&w, &.{ "a;b", "c,d" }, .{ .separator = ';', .line_ending = "\r\n" });
    try testing.expectEqualStrings(
        "plain,\"a,b\",\"say \"\"hi\"\"\",\"two\nlines\",\"cr\r\",, pad \n" ++
            "\"\"\n" ++
            "\n" ++
            "\"a;b\";c,d\r\n",
        w.buffered(),
    );
}

test "write then read round-trips" {
    const rows: []const []const []const u8 = &.{
        &.{ "id", "name", "bio" },
        &.{ "1", "Ada", "wrote \"Notes\", 1843" },
        &.{ "2", "", "line one\r\nline two\nline three" },
        &.{""},
        &.{},
        &.{ "\"", "\"\"", ",", "\r" },
        &.{ "last", "row" },
    };
    for ([_]Options{ .{}, .{ .line_ending = "\r\n" }, .{ .separator = '\t' } }) |options| {
        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();
        for (rows) |row| try writeRow(&out.writer, row, options);
        try expectRows(out.written(), options, rows);
    }
}
