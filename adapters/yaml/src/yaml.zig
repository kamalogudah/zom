//! A documented subset of YAML: datasets of flat records. Nothing here knows
//! about zom; the gateway decodes each value with `zom.codec`.
//!
//! Two top-level shapes:
//!
//! - `parseDatasets`: a mapping from dataset name to a block sequence of
//!   records (one file holding every dataset).
//! - `parseRecords`: a bare block sequence of records (one file per dataset).
//!
//! ```yaml
//! users:
//!   - id: 1
//!     name: Achieng
//!     email: "achieng@example.com"
//!     deleted_at: ~
//!   - id: 2
//!     name: 'Otieno'
//! posts: []
//! ```
//!
//! What is accepted:
//!
//! - A record is a block mapping from keys to scalars. It starts on the `-`
//!   line (`- id: 1`) or on the lines after a bare `-`.
//! - A dataset's sequence may be indented under its name or written at the
//!   same column (`users:\n- id: 1`). `users:`, `users: ~` and `users: []`
//!   are empty datasets.
//! - Scalars are plain (`Achieng`), single-quoted (`'it''s'`, where `''` is a
//!   quote) or double-quoted (`"a\tb"`, with every YAML escape:
//!   `\" \\ \/ \0 \a \b \t \n \v \f \r \e \  \N \_ \L \P \xXX \uXXXX
//!   \UXXXXXXXX`). Quoted keys are allowed too.
//! - A plain `~`, `null`, `Null`, `NULL` or an empty value is null
//!   (`Field.value == null`). A quoted `"~"` or `""` is a string.
//! - `#` comments, on their own line or after a value (a `#` must follow a
//!   space or tab to start a comment, so `a#b` is data), blank lines,
//!   `\r\n` line endings, a UTF-8 byte order mark and a leading `---`.
//! - Indentation is spaces only. A tab in indentation is
//!   `error.TabIndentation`, as YAML says. Tabs between tokens are fine.
//!
//! Everything else that is valid YAML fails with `error.UnsupportedYaml`, and
//! the `Diagnostic` gives its line and says what was found: anchors and
//! aliases, tags, block scalars (`|`, `>`), flow collections (`[..]`, `{..}`),
//! nested mappings and sequences, complex keys (`?`), directives (`%YAML`),
//! a second document or `...`, multi-line scalars, and records that are not
//! mappings. Malformed input fails with one of the other `Error` values.
//!
//! Memory: the result owns an arena holding every list and every unescaped
//! string. Values without escapes are sub-slices of `input`, so `input`
//! must outlive the result. On error nothing is leaked.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    /// Valid YAML outside the subset. `Diagnostic.detail` says what.
    UnsupportedYaml,
    /// A tab in a line's indentation (or between `-` and a record's first key).
    TabIndentation,
    /// A line not indented to match its record, sequence or dataset name.
    BadIndentation,
    /// A quoted scalar that doesn't close on the line it opens.
    UnterminatedQuote,
    /// A `\` in a double-quoted scalar not followed by a YAML escape.
    InvalidEscape,
    /// The same key twice in a record, or the same dataset name twice.
    DuplicateKey,
    /// Malformed input; `Diagnostic.detail` says what was expected.
    InvalidSyntax,
} || Allocator.Error;

/// Where parsing failed. Zig errors carry no data, so the parser fills this
/// in when one is passed. Formatted with `{f}` it reads
/// `3:5: unsupported YAML: an anchor (&name)`; the gateway prefixes the file
/// name.
pub const Diagnostic = struct {
    /// 1-based line.
    line: usize = 0,
    /// 1-based byte column within that line.
    column: usize = 0,
    err: ?Error = null,
    /// A static phrase saying what was found or expected; may be empty.
    detail: []const u8 = "",

    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}:{d}: ", .{ d.line, d.column });
        const err = d.err orelse return w.writeAll("no error");
        try w.writeAll(switch (err) {
            error.UnsupportedYaml => "unsupported YAML",
            error.TabIndentation => "tab in indentation (YAML indents with spaces only)",
            error.BadIndentation => "wrong indentation",
            error.UnterminatedQuote => "unterminated quote (a quoted scalar must close on the line it opens)",
            error.InvalidEscape => "invalid escape sequence",
            error.DuplicateKey => "duplicate key",
            error.InvalidSyntax => "invalid syntax",
            error.OutOfMemory => "out of memory",
        });
        if (d.detail.len != 0) try w.print(": {s}", .{d.detail});
    }
};

/// One `key: value` of a record.
pub const Field = struct {
    key: []const u8,
    /// `null` for `~`, `null`, `Null`, `NULL` or nothing; otherwise the
    /// scalar's text with quotes removed and escapes applied.
    value: ?[]const u8,
    /// 1-based line of the key, for decode errors.
    line: usize,
};

/// One item of a sequence: its fields in file order, keys unique.
pub const Record = struct {
    /// 1-based line of the record's `-`.
    line: usize,
    fields: []const Field,

    /// The field named `key`, or null when the record doesn't have it.
    pub fn get(r: Record, key: []const u8) ?Field {
        for (r.fields) |f| if (std.mem.eql(u8, f.key, key)) return f;
        return null;
    }
};

pub const Dataset = struct {
    name: []const u8,
    /// 1-based line of the name.
    line: usize,
    records: []const Record,
};

/// The result of `parseDatasets`. Valid while `input` is; free with `deinit`.
pub const Datasets = struct {
    arena: std.heap.ArenaAllocator,
    /// In file order, names unique.
    items: []const Dataset,

    pub fn deinit(self: *Datasets) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: Datasets, name: []const u8) ?Dataset {
        for (self.items) |d| if (std.mem.eql(u8, d.name, name)) return d;
        return null;
    }
};

/// The result of `parseRecords`. Valid while `input` is; free with `deinit`.
pub const Records = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Record,

    pub fn deinit(self: *Records) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Parses a mapping of dataset names to sequences of records. Empty input
/// has no datasets.
pub fn parseDatasets(gpa: Allocator, input: []const u8, diag: ?*Diagnostic) Error!Datasets {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p: Parser = .init(arena.allocator(), input, diag);
    const items = try p.datasets();
    return .{ .arena = arena, .items = items };
}

/// Parses a bare sequence of records. Empty input has no records.
pub fn parseRecords(gpa: Allocator, input: []const u8, diag: ?*Diagnostic) Error!Records {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    var p: Parser = .init(arena.allocator(), input, diag);
    const items = try p.records();
    return .{ .arena = arena, .items = items };
}

/// A line with content: not blank and not only a comment.
const Line = struct {
    number: usize,
    /// Leading spaces, which is also the 0-based column of `text[0]`.
    indent: usize,
    /// From the first non-space byte to the end, without the line break.
    text: []const u8,
};

const Parser = struct {
    arena: Allocator,
    input: []const u8,
    diag: ?*Diagnostic,
    pos: usize = 0,
    line_no: usize = 0,
    peeked: ?Line = null,
    seen_content: bool = false,

    fn init(arena: Allocator, input: []const u8, diag: ?*Diagnostic) Parser {
        const bom = "\xEF\xBB\xBF";
        return .{
            .arena = arena,
            .input = input,
            .diag = diag,
            .pos = if (std.mem.startsWith(u8, input, bom)) bom.len else 0,
        };
    }

    // ------------------------------------------------------------ structure

    fn datasets(p: *Parser) Error![]const Dataset {
        var list: std.ArrayList(Dataset) = .empty;
        const first = try p.peek() orelse return &.{};
        const root = first.indent;
        if (isItem(first.text))
            return p.fail(error.UnsupportedYaml, first, 0, "a top-level sequence (expected dataset names; use parseRecords for one dataset per file)");

        while (try p.peek()) |line| {
            if (line.indent != root)
                return p.fail(error.BadIndentation, line, 0, "a dataset name must line up with the first one");
            if (isItem(line.text))
                return p.fail(error.InvalidSyntax, line, 0, "expected a dataset name, found '-'");
            p.take();
            const kv = try p.key(line);
            for (list.items) |d| if (std.mem.eql(u8, d.name, kv.key))
                return p.fail(error.DuplicateKey, line, 0, "a dataset name used twice");

            const value = trimComment(kv.rest);
            var items: []const Record = &.{};
            if (std.mem.eql(u8, value, "[]")) {
                // An empty dataset, the one flow collection we accept.
            } else if (try p.scalar(line, kv.rest, kv.rest_off) != null) {
                return p.fail(error.InvalidSyntax, line, kv.rest_off, "a dataset name must be followed by a sequence of records");
            } else {
                items = try p.sequence(root);
            }
            try list.append(p.arena, .{ .name = kv.key, .line = line.number, .records = items });
        }
        return list.items;
    }

    fn records(p: *Parser) Error![]const Record {
        const first = try p.peek() orelse return &.{};
        if (!isItem(first.text))
            return p.fail(error.UnsupportedYaml, first, 0, "a top-level mapping (expected a sequence of records; use parseDatasets for several datasets in one file)");
        const items = try p.sequence(null);
        if (try p.peek()) |line|
            return p.fail(error.BadIndentation, line, 0, "a line outdented past the top-level sequence");
        return items;
    }

    /// A block sequence of records. `parent` is the indent of the dataset
    /// name it belongs to, or null at the top level. A sequence may sit at
    /// the parent's column; a non-`-` line there ends it.
    fn sequence(p: *Parser, parent: ?usize) Error![]const Record {
        var list: std.ArrayList(Record) = .empty;
        const first = try p.peek() orelse return &.{};
        if (parent) |pi| {
            if (first.indent < pi) return &.{}; // the caller reports it
            if (!isItem(first.text)) {
                if (first.indent > pi)
                    return p.fail(error.UnsupportedYaml, first, 0, "a nested mapping (a dataset must be a sequence of records)");
                return &.{}; // the next dataset: this one is empty
            }
        }
        const indent = first.indent;
        while (try p.peek()) |line| {
            if (line.indent < indent) break;
            if (line.indent > indent)
                return p.fail(error.BadIndentation, line, 0, "neither a key of the record above nor a new '-' item");
            if (!isItem(line.text)) {
                if (parent != null and parent.? == indent) break;
                return p.fail(error.InvalidSyntax, line, 0, "expected '-' to start a record");
            }
            p.take();
            try list.append(p.arena, try p.record(line));
        }
        return list.items;
    }

    /// The record starting at the `-` of `item`, and its following lines.
    fn record(p: *Parser, item: Line) Error!Record {
        var fields: std.ArrayList(Field) = .empty;
        const after = item.text[1..];
        const sep = std.mem.indexOfNone(u8, after, " \t") orelse after.len;
        const rest = after[sep..];

        // Keys of this record line up at `column`, and `open` says whether the
        // last key had nothing after it (a nested block would follow it).
        var column: usize = undefined;
        var open = false;
        if (rest.len == 0 or rest[0] == '#') {
            const next = try p.peek();
            if (next == null or next.?.indent <= item.indent)
                return p.fail(error.UnsupportedYaml, item, 0, "an empty sequence item (a record must be a mapping)");
            column = next.?.indent;
        } else {
            if (std.mem.indexOfScalar(u8, after[0..sep], '\t')) |t|
                return p.fail(error.TabIndentation, item, 1 + t, "");
            column = item.indent + 1 + sep;
            const first: Line = .{ .number = item.number, .indent = column, .text = rest };
            // `- 5` is valid YAML, just not a record.
            if (rest[0] != '"' and rest[0] != '\'' and !isItem(rest)) {
                try p.checkIndicator(first, rest, 0);
                if (findMapColon(rest) == null)
                    return p.fail(error.UnsupportedYaml, first, 0, "a scalar sequence item (a record must be a mapping)");
            }
            open = try p.field(&fields, first);
        }

        while (try p.peek()) |line| {
            if (line.indent < column) break;
            if (line.indent > column) {
                if (open) return p.fail(error.UnsupportedYaml, line, 0, "a nested value (a record's values must be scalars)");
                return p.fail(error.BadIndentation, line, 0, "deeper than the other keys of its record");
            }
            p.take();
            open = try p.field(&fields, line);
        }
        return .{ .line = item.number, .fields = fields.items };
    }

    /// Adds `line`'s `key: value` to `fields`. Returns whether the value was
    /// left out entirely (so a nested block could follow).
    fn field(p: *Parser, fields: *std.ArrayList(Field), line: Line) Error!bool {
        if (isItem(line.text))
            return p.fail(error.UnsupportedYaml, line, 0, "a nested sequence (a record must be a mapping)");
        const kv = try p.key(line);
        for (fields.items) |f| if (std.mem.eql(u8, f.key, kv.key))
            return p.fail(error.DuplicateKey, line, 0, "a key used twice in one record");
        const value = try p.scalar(line, kv.rest, kv.rest_off);
        try fields.append(p.arena, .{ .key = kv.key, .value = value, .line = line.number });
        return trimComment(kv.rest).len == 0;
    }

    // ------------------------------------------------------------ keys and scalars

    const KeyValue = struct {
        key: []const u8,
        /// After the `:` and the whitespace following it.
        rest: []const u8,
        /// Offset of `rest[0]` in the line's text.
        rest_off: usize,
    };

    /// Splits `line` into its key and what follows `: `.
    fn key(p: *Parser, line: Line) Error!KeyValue {
        const text = line.text;
        var name: []const u8 = undefined;
        var colon: usize = undefined;
        switch (text[0]) {
            '"', '\'' => {
                const q = try p.quoted(line, text, 0);
                name = q.value;
                const ws = std.mem.indexOfNonePos(u8, text, q.len, " \t") orelse text.len;
                if (ws == text.len or text[ws] != ':' or !separated(text, ws + 1))
                    return p.fail(error.InvalidSyntax, line, ws, "expected ': ' after the quoted key");
                colon = ws;
            },
            else => {
                try p.checkIndicator(line, text, 0);
                colon = findMapColon(text) orelse
                    return p.fail(error.InvalidSyntax, line, 0, "expected 'key: value'");
                name = std.mem.trimEnd(u8, text[0..colon], " \t");
            },
        }
        const start = std.mem.indexOfNonePos(u8, text, colon + 1, " \t") orelse text.len;
        return .{ .key = name, .rest = text[start..], .rest_off = start };
    }

    /// The scalar `s` (a value after `key: `, at offset `off` in
    /// `line.text`), or null for the null forms.
    fn scalar(p: *Parser, line: Line, s: []const u8, off: usize) Error!?[]const u8 {
        if (s.len == 0 or s[0] == '#') return null;
        switch (s[0]) {
            '"', '\'' => {
                const q = try p.quoted(line, s, off);
                const tail = s[q.len..];
                const ws = std.mem.indexOfNone(u8, tail, " \t") orelse return q.value;
                if (ws > 0 and tail[ws] == '#') return q.value;
                return p.fail(error.InvalidSyntax, line, off + q.len + ws, "unexpected text after the closing quote");
            },
            else => {
                try p.checkIndicator(line, s, off);
                const v = trimComment(s);
                if (findMapColon(v) != null)
                    return p.fail(error.InvalidSyntax, line, off, "': ' inside a plain value (quote the value, or nested mappings are not supported)");
                if (isNull(v)) return null;
                return v;
            },
        }
    }

    const Quoted = struct {
        value: []const u8,
        /// Bytes of `s` taken, including both quotes.
        len: usize,
    };

    /// The quoted scalar at the start of `s`. `off` is `s[0]`'s offset in
    /// `line.text`, for error columns.
    fn quoted(p: *Parser, line: Line, s: []const u8, off: usize) Error!Quoted {
        return if (s[0] == '\'') p.singleQuoted(line, s, off) else p.doubleQuoted(line, s, off);
    }

    fn singleQuoted(p: *Parser, line: Line, s: []const u8, off: usize) Error!Quoted {
        var escaped = false;
        var i: usize = 1;
        while (true) {
            i = std.mem.indexOfScalarPos(u8, s, i, '\'') orelse
                return p.fail(error.UnterminatedQuote, line, off, "");
            if (i + 1 < s.len and s[i + 1] == '\'') {
                escaped = true;
                i += 2;
                continue;
            }
            break;
        }
        const raw = s[1..i];
        if (!escaped) return .{ .value = raw, .len = i + 1 };
        const buf = try p.arena.alloc(u8, raw.len);
        var n: usize = 0;
        var j: usize = 0;
        while (j < raw.len) : (j += 1) {
            buf[n] = raw[j];
            n += 1;
            if (raw[j] == '\'') j += 1; // skip the second quote of the pair
        }
        return .{ .value = buf[0..n], .len = i + 1 };
    }

    fn doubleQuoted(p: *Parser, line: Line, s: []const u8, off: usize) Error!Quoted {
        var i: usize = 1;
        var escaped = false;
        while (i < s.len and s[i] != '"') {
            if (s[i] == '\\') {
                escaped = true;
                i += 1;
            }
            i += 1;
        }
        if (i >= s.len) return p.fail(error.UnterminatedQuote, line, off, "");
        const raw = s[1..i];
        if (!escaped) return .{ .value = raw, .len = i + 1 };

        // The worst growth is `\L` and `\P`: 2 bytes written, 3 in UTF-8.
        const buf = try p.arena.alloc(u8, raw.len + raw.len / 2);
        var n: usize = 0;
        var j: usize = 0;
        while (j < raw.len) {
            const c = raw[j];
            if (c != '\\') {
                buf[n] = c;
                n += 1;
                j += 1;
                continue;
            }
            const at = off + 1 + j; // offset of the backslash in line.text
            const e = raw[j + 1];
            j += 2;
            const simple: ?u8 = switch (e) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                ' ' => ' ',
                '\t' => '\t',
                '0' => 0,
                'a' => 0x07,
                'b' => 0x08,
                't' => '\t',
                'n' => '\n',
                'v' => 0x0B,
                'f' => 0x0C,
                'r' => '\r',
                'e' => 0x1B,
                else => null,
            };
            if (simple) |b| {
                buf[n] = b;
                n += 1;
                continue;
            }
            const cp: u21 = switch (e) {
                'N' => 0x85,
                '_' => 0xA0,
                'L' => 0x2028,
                'P' => 0x2029,
                'x', 'u', 'U' => blk: {
                    const digits: usize = switch (e) {
                        'x' => 2,
                        'u' => 4,
                        else => 8,
                    };
                    if (j + digits > raw.len)
                        return p.fail(error.InvalidEscape, line, at, "too few hex digits");
                    const v = std.fmt.parseInt(u32, raw[j..][0..digits], 16) catch
                        return p.fail(error.InvalidEscape, line, at, "not a hex number");
                    j += digits;
                    if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF))
                        return p.fail(error.InvalidEscape, line, at, "not a Unicode scalar value");
                    break :blk @intCast(v);
                },
                else => return p.fail(error.InvalidEscape, line, at, "YAML has no such escape"),
            };
            n += std.unicode.utf8Encode(cp, buf[n..]) catch unreachable;
        }
        return .{ .value = buf[0..n], .len = i + 1 };
    }

    /// Rejects a scalar or key that starts with a YAML indicator we don't
    /// support. `off` is `s[0]`'s offset in `line.text`.
    fn checkIndicator(p: *Parser, line: Line, s: []const u8, off: usize) Error!void {
        const spaced = separated(s, 1);
        const what: []const u8 = switch (s[0]) {
            '&' => "an anchor (&name)",
            '*' => "an alias (*name)",
            '!' => "a tag (!type)",
            '|', '>' => "a block scalar (| or >)",
            '[', '{' => "a flow collection ([...] or {...})",
            '?' => if (spaced) "a complex key (? key)" else return,
            '-' => if (spaced) "a nested sequence (a record's values must be scalars)" else return,
            '%' => "a directive (%)",
            ':' => if (spaced) return p.fail(error.InvalidSyntax, line, off, "a value without a key") else return,
            '@', '`' => return p.fail(error.InvalidSyntax, line, off, "'@' and '`' are reserved and cannot start a plain scalar"),
            ',', ']', '}' => return p.fail(error.InvalidSyntax, line, off, "a flow indicator cannot start a plain scalar"),
            else => return,
        };
        return p.fail(error.UnsupportedYaml, line, off, what);
    }

    // ------------------------------------------------------------ lines

    fn peek(p: *Parser) Error!?Line {
        if (p.peeked == null) p.peeked = try p.readLine();
        return p.peeked;
    }

    fn take(p: *Parser) void {
        p.peeked = null;
    }

    /// The next line with content, skipping blank and comment-only lines.
    fn readLine(p: *Parser) Error!?Line {
        const input = p.input;
        while (p.pos < input.len) {
            const start = p.pos;
            const nl = std.mem.indexOfScalarPos(u8, input, start, '\n');
            p.pos = if (nl) |i| i + 1 else input.len;
            p.line_no += 1;
            var raw = input[start .. nl orelse input.len];
            if (raw.len > 0 and raw[raw.len - 1] == '\r') raw = raw[0 .. raw.len - 1];

            const indent = std.mem.indexOfNone(u8, raw, " ") orelse continue;
            const content = std.mem.indexOfNonePos(u8, raw, indent, " \t") orelse continue;
            if (raw[content] == '#') continue;
            const line: Line = .{ .number = p.line_no, .indent = indent, .text = raw[indent..] };
            // `raw[indent]` is not a space, so whitespace before the content
            // is a tab.
            if (content != indent) return p.fail(error.TabIndentation, line, 0, "");

            if (indent == 0) {
                if (marker(line.text, "---")) |after| {
                    if (!p.seen_content and trimComment(after).len == 0) continue;
                    return p.fail(error.UnsupportedYaml, line, 0, if (p.seen_content)
                        "a second document (---)"
                    else
                        "content on the '---' line");
                }
                if (marker(line.text, "...") != null)
                    return p.fail(error.UnsupportedYaml, line, 0, "a document end marker (...)");
            }
            p.seen_content = true;
            return line;
        }
        return null;
    }

    /// Records the error in the diagnostic. `off` is an offset in `line.text`.
    fn fail(p: *Parser, err: Error, line: Line, off: usize, detail: []const u8) Error {
        if (p.diag) |d| d.* = .{
            .line = line.number,
            .column = line.indent + off + 1,
            .err = err,
            .detail = detail,
        };
        return err;
    }
};

/// Whether `text` is a block sequence item: `-` then whitespace or the end.
fn isItem(text: []const u8) bool {
    return text[0] == '-' and separated(text, 1);
}

/// Whether `s[i]` is whitespace or past the end.
fn separated(s: []const u8, i: usize) bool {
    return i >= s.len or s[i] == ' ' or s[i] == '\t';
}

/// The index of the `:` ending a plain key: the first one followed by
/// whitespace or the end, unless a comment starts first.
fn findMapColon(s: []const u8) ?usize {
    for (s, 0..) |c, i| switch (c) {
        ':' => if (separated(s, i + 1)) return i,
        '#' => if (i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t')) return null,
        else => {},
    };
    return null;
}

/// `s` without a trailing ` # comment` and trailing whitespace.
fn trimComment(s: []const u8) []const u8 {
    var end = s.len;
    if (s.len > 0 and s[0] == '#') {
        end = 0;
    } else for (s, 0..) |c, i| {
        if (c == '#' and i > 0 and (s[i - 1] == ' ' or s[i - 1] == '\t')) {
            end = i;
            break;
        }
    }
    return std.mem.trimEnd(u8, s[0..end], " \t");
}

fn isNull(v: []const u8) bool {
    const forms = [_][]const u8{ "", "~", "null", "Null", "NULL" };
    for (forms) |f| if (std.mem.eql(u8, v, f)) return true;
    return false;
}

/// If `text` is the document marker `m` (alone or followed by whitespace),
/// what follows it.
fn marker(text: []const u8, m: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, text, m) or !separated(text, m.len)) return null;
    return std.mem.trimStart(u8, text[m.len..], " \t");
}
