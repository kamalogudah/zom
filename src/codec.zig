//! Text cells to tuple fields, for adapters whose rows arrive as strings
//! (CSV, YAML scalars, SQL text results). Every adapter decodes through here,
//! so a bad cell reads the same whatever file or database it came from.
//!
//! Rules, per field type:
//!
//! | Type | Accepted text | Error |
//! |---|---|---|
//! | integers | `std.fmt.parseInt(F, text, 10)`: optional `+`/`-`, digits, `_` between digits. `"-0"` is `0`, even for unsigned types. | `InvalidInt`, or `ValueOutOfRange` when it doesn't fit (`"256"` for a `u8`, `"-1"` for a `u32`) |
//! | floats | `std.fmt.parseFloat`: decimal or hex, exponents, `inf`, `nan` | `InvalidFloat` |
//! | `bool` | `true`, `false`, `1`, `0`, `t`, `f`, case-insensitive | `InvalidBool` |
//! | enums | a tag name, exact case (`std.meta.stringToEnum`) | `InvalidEnum` |
//! | `[]const u8` | anything, returned as it is (it borrows `text`) | none |
//! | `?T` | `Options.null_text` is `null`, anything else decodes as `T` | `T`'s |
//!
//! Whitespace is never trimmed: `" 5"` is `InvalidInt`, and `" Ada"` keeps its
//! space. A format that allows padding trims before decoding, so strings and
//! numbers agree on what the cell contains.
//!
//! A non-optional, non-string field given `null_text` (by default `""`) is
//! `UnexpectedNull`, so an empty CSV cell in an integer column says "empty"
//! rather than "not an integer". A string field takes it as a value.

const std = @import("std");

pub const DecodeError = error{
    InvalidInt,
    InvalidFloat,
    InvalidBool,
    InvalidEnum,
    ValueOutOfRange,
    /// `decodeRow`: no cell for a field that has no default and isn't optional.
    MissingField,
    /// The cell is `Options.null_text`, but the field is not optional.
    UnexpectedNull,
};

pub const Options = struct {
    /// The text that means `null`: an optional field decodes it to `null`,
    /// any other non-string field fails with `error.UnexpectedNull`. `""`
    /// suits CSV; a SQL text result might use `"NULL"`. `null` turns it off,
    /// so every cell is decoded as a value.
    null_text: ?[]const u8 = "",
    /// `decodeRow` only: `columns[i]` is the index in `cells` of field `i`
    /// (in declaration order), or `null` when the source has no such column.
    /// Its length must equal the field count. When this is `null`, cells are
    /// in field order. An adapter builds it once from a header row.
    columns: ?[]const ?usize = null,
    /// `decodeRow` only: copied into `Diagnostic.row`. 1-based by convention,
    /// e.g. the line number in a CSV file; 0 means unknown.
    row: usize = 0,
};

/// What went wrong, filled in by `decodeRow` when it returns an error.
/// Zig errors carry no data, so the details go here (the same pattern as
/// `std.json.Diagnostics`). Formatted with `{f}` it reads
/// `14:3 (age): "abc" is not an integer from 0 to 255`; an adapter prefixes
/// the file name.
pub const Diagnostic = struct {
    /// `Options.row`.
    row: usize = 0,
    /// 1-based index of the cell in the source row, or 0 when the field has
    /// no column at all (`Options.columns` maps it to `null`).
    column: usize = 0,
    /// The tuple field being decoded.
    field: []const u8 = "",
    /// The cell's text, borrowed from `cells`. Empty for `MissingField`.
    text: []const u8 = "",
    err: ?DecodeError = null,
    /// What the field accepts, e.g. "a boolean (true, false, 1, 0, t, f)".
    expected: []const u8 = "",

    pub fn format(d: Diagnostic, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}", .{d.row});
        if (d.column != 0) try w.print(":{d}", .{d.column});
        try w.print(" ({s}): ", .{d.field});
        const err = d.err orelse return w.writeAll("no error");
        switch (err) {
            error.MissingField => try w.writeAll("missing value"),
            error.UnexpectedNull => if (d.text.len == 0)
                try w.writeAll("empty, but the field is not optional")
            else
                try w.print("\"{s}\" means null, but the field is not optional", .{d.text}),
            error.ValueOutOfRange => try w.print("\"{s}\" is out of range, expected {s}", .{ d.text, d.expected }),
            else => try w.print("\"{s}\" is not {s}", .{ d.text, d.expected }),
        }
    }
};

/// Parses one cell into `F`. See the module comment for what each type
/// accepts. A string result is `text` itself, not a copy: the caller
/// (usually `memory.Store`, which copies on insert) owns its lifetime.
pub fn decodeField(comptime F: type, text: []const u8, opts: Options) DecodeError!F {
    if (@typeInfo(F) == .optional) {
        if (isNull(text, opts)) return null;
        return try decodeField(@typeInfo(F).optional.child, text, opts);
    }
    if (comptime isText(F)) return text;
    if (isNull(text, opts)) return error.UnexpectedNull;

    switch (@typeInfo(F)) {
        .int => return std.fmt.parseInt(F, text, 10) catch |e| switch (e) {
            error.Overflow => error.ValueOutOfRange,
            error.InvalidCharacter => error.InvalidInt,
        },
        .float => return std.fmt.parseFloat(F, text) catch error.InvalidFloat,
        .bool => return parseBool(text),
        .@"enum" => return std.meta.stringToEnum(F, text) orelse error.InvalidEnum,
        .pointer => @compileError("zom.codec: string fields must be []const u8, got " ++ @typeName(F)),
        else => @compileError("zom.codec: unsupported field type " ++ @typeName(F)),
    }
}

/// Builds a `T` from one row of cells. Cells are in field order, or placed by
/// `opts.columns`; extra cells are ignored. A field with no cell takes its
/// default value if it has one, else `null` if it is optional, else the row
/// fails with `error.MissingField`.
///
/// String fields borrow from `cells`. On error, `diag` (if given) says which
/// field and cell failed.
pub fn decodeRow(comptime T: type, cells: []const []const u8, opts: Options, diag: ?*Diagnostic) DecodeError!T {
    if (@typeInfo(T) != .@"struct")
        @compileError("zom.codec.decodeRow: expected a tuple struct, got " ++ @typeName(T));
    const fields = @typeInfo(T).@"struct".fields;
    if (opts.columns) |c| std.debug.assert(c.len == fields.len);

    var out: T = undefined;
    inline for (fields, 0..) |f, i| {
        const index: ?usize = if (opts.columns) |c| c[i] else i;
        const cell: ?[]const u8 = if (index) |x| (if (x < cells.len) cells[x] else null) else null;
        const column = if (index) |x| x + 1 else 0;

        if (cell) |text| {
            @field(out, f.name) = decodeField(f.type, text, opts) catch |err| {
                if (diag) |d| d.* = .{
                    .row = opts.row,
                    .column = column,
                    .field = f.name,
                    .text = text,
                    .err = err,
                    .expected = comptime expected(f.type),
                };
                return err;
            };
        } else if (comptime f.defaultValue()) |default| {
            @field(out, f.name) = default;
        } else if (@typeInfo(f.type) == .optional) {
            @field(out, f.name) = null;
        } else {
            if (diag) |d| d.* = .{
                .row = opts.row,
                .column = column,
                .field = f.name,
                .err = error.MissingField,
                .expected = comptime expected(f.type),
            };
            return error.MissingField;
        }
    }
    return out;
}

/// Case-insensitive `true`/`false`/`1`/`0`/`t`/`f`.
fn parseBool(text: []const u8) DecodeError!bool {
    const truthy = [_][]const u8{ "true", "t", "1" };
    const falsy = [_][]const u8{ "false", "f", "0" };
    for (truthy) |s| if (std.ascii.eqlIgnoreCase(text, s)) return true;
    for (falsy) |s| if (std.ascii.eqlIgnoreCase(text, s)) return false;
    return error.InvalidBool;
}

fn isNull(text: []const u8, opts: Options) bool {
    const n = opts.null_text orelse return false;
    return std.mem.eql(u8, text, n);
}

fn isText(comptime F: type) bool {
    return switch (@typeInfo(F)) {
        .pointer => |p| p.size == .slice and p.child == u8 and p.is_const,
        else => false,
    };
}

/// A description of what a field of type `F` accepts, for `Diagnostic`.
fn expected(comptime F: type) []const u8 {
    return switch (@typeInfo(F)) {
        .optional => |o| expected(o.child),
        .int => std.fmt.comptimePrint("an integer from {d} to {d}", .{ std.math.minInt(F), std.math.maxInt(F) }),
        .float => "a number",
        .bool => "a boolean (true, false, 1, 0, t, f)",
        .@"enum" => |e| blk: {
            var s: []const u8 = "one of:";
            for (e.fields, 0..) |tag, i| s = s ++ (if (i == 0) " " else ", ") ++ tag.name;
            break :blk s;
        },
        else => "text",
    };
}
