//! Adapter-agnostic query description.
//!
//! A relation never runs anything itself. It only builds up a `Query(T)`
//! value (filters, ordering, limit/offset). Each adapter decides what that
//! means: the memory adapter evaluates it against rows, the SQL adapter
//! compiles it into a statement. This is the seam ROM draws between
//! relations and datasets.

const std = @import("std");

pub const Op = enum {
    eq,
    neq,
    lt,
    lte,
    gt,
    gte,
    /// The attribute is one of a list of values (`Operand.many`).
    in,
    /// The attribute is none of a list of values (`Operand.many`).
    not_in,
    /// SQL `LIKE`: `%` matches any run of characters, `_` exactly one, and
    /// `\` makes the next character literal (`\%`, `\_`, `\\`).
    like,
    /// `like`, ignoring ASCII case (Postgres `ILIKE`).
    ilike,
    /// `lo <= attribute <= hi`, both ends inclusive (`Operand.range`).
    between,
    is_null,
    is_not_null,

    pub fn sql(op: Op) []const u8 {
        return switch (op) {
            .eq => "=",
            .neq => "<>",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
            .in => "IN",
            .not_in => "NOT IN",
            .like => "LIKE",
            .ilike => "ILIKE",
            .between => "BETWEEN",
            .is_null => "IS NULL",
            .is_not_null => "IS NOT NULL",
        };
    }

    /// Which `Operand` variant a filter with this op carries.
    pub fn operand(op: Op) std.meta.Tag(Operand) {
        return switch (op) {
            .eq, .neq, .lt, .lte, .gt, .gte, .like, .ilike => .one,
            .in, .not_in => .many,
            .between => .range,
            .is_null, .is_not_null => .none,
        };
    }
};

/// The value side of a filter. Building one never allocates: `one` and
/// `range` hold their values inline, and `many` borrows a list.
pub const Operand = union(enum) {
    /// `is_null`, `is_not_null`.
    none,
    one: Value,
    /// `in`, `not_in`.
    many: ValueList,
    /// `between`: `.{ lo, hi }`, both inclusive.
    range: [2]Value,
};

/// A borrowed, read-only list of values, for `in` and `not_in`.
///
/// It points at the caller's typed slice (`[]const u32`, `[]const Role`,
/// ...) and converts each element to a `Value` when read, so `whereIn` with
/// a runtime slice copies nothing. Ownership: the list never owns its
/// items. Whoever built it must keep the slice alive, unchanged, for as long
/// as the list (or a query or relation holding it) is used. `where` with a
/// comptime tuple points it at a static array, which lives forever.
pub const ValueList = struct {
    ctx: *const anyopaque,
    len: usize,
    atFn: *const fn (ctx: *const anyopaque, index: usize) Value,

    /// Borrows `items`; see the ownership rule above.
    pub fn of(comptime E: type, items: []const E) ValueList {
        const Impl = struct {
            fn at(ctx: *const anyopaque, i: usize) Value {
                const p: [*]const E = @ptrCast(@alignCast(ctx));
                return if (E == Value) p[i] else toValue(p[i]);
            }
        };
        return .{ .ctx = @ptrCast(items.ptr), .len = items.len, .atFn = Impl.at };
    }

    pub fn at(self: ValueList, index: usize) Value {
        std.debug.assert(index < self.len);
        return self.atFn(self.ctx, index);
    }
};

/// How `like` compares characters.
pub const Case = enum { sensitive, insensitive };

/// SQL `LIKE` matching, without regex: `%` matches any run of characters
/// (including none), `_` exactly one, and `\` escapes the next character.
/// A trailing lone `\` matches a literal `\`. "Character" means a UTF-8
/// code point, as in a Postgres UTF8 database; bytes that are not valid
/// UTF-8 count as one character each. `.insensitive` folds ASCII only.
///
/// Iterative, remembering only the last `%`: when a later literal fails,
/// that `%` swallows one more character and matching resumes after it.
/// That is enough because a later `%` can absorb anything an earlier one
/// could, so this runs in O(text.len * pattern.len) time and O(1) space.
pub fn like(text: []const u8, pattern: []const u8, case: Case) bool {
    var t: usize = 0;
    var p: usize = 0;
    // Where to resume after the last `%`: the pattern index just past it,
    // and the text index it has consumed up to.
    var star: ?struct { p: usize, t: usize } = null;

    while (t < text.len) {
        if (p < pattern.len) {
            const c = pattern[p];
            if (c == '%') {
                p += 1;
                star = .{ .p = p, .t = t };
                continue;
            }
            if (c == '_') {
                t += charLen(text, t);
                p += 1;
                continue;
            }
            var lit = c;
            var width: usize = 1;
            if (c == '\\' and p + 1 < pattern.len) {
                lit = pattern[p + 1];
                width = 2;
            }
            if (sameByte(lit, text[t], case)) {
                t += 1;
                p += width;
                continue;
            }
        }
        const s = if (star) |*s| s else return false;
        s.t += charLen(text, s.t);
        t = s.t;
        p = s.p;
    }
    while (p < pattern.len and pattern[p] == '%') p += 1;
    return p == pattern.len;
}

/// Bytes in the UTF-8 sequence starting at `text[i]`, or 1 when it is not a
/// valid sequence start or would run past the end.
fn charLen(text: []const u8, i: usize) usize {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return 1;
    return if (i + n <= text.len) n else 1;
}

fn sameByte(a: u8, b: u8, case: Case) bool {
    return switch (case) {
        .sensitive => a == b,
        .insensitive => std.ascii.toLower(a) == std.ascii.toLower(b),
    };
}

pub const Direction = enum { asc, desc };

/// Runtime value carried by filters and changes. Small on purpose: every
/// attribute type a schema supports maps onto one of these.
pub const Value = union(enum) {
    null,
    boolean: bool,
    int: i64,
    /// Unsigned values that do not fit `int` (u64, usize on 64-bit targets).
    uint: u64,
    float: f64,
    string: []const u8,

    /// Total order within a kind; `null` when the two values are not comparable.
    pub fn order(a: Value, b: Value) ?std.math.Order {
        return switch (a) {
            .null => if (b == .null) .eq else null,
            .boolean => |x| if (b == .boolean)
                std.math.order(@intFromBool(x), @intFromBool(b.boolean))
            else
                null,
            .int => |x| switch (b) {
                .int => |y| std.math.order(x, y),
                // Widening to i128 holds every i64 and u64 value exactly.
                .uint => |y| std.math.order(@as(i128, x), @as(i128, y)),
                .float => |y| std.math.order(@as(f64, @floatFromInt(x)), y),
                else => null,
            },
            .uint => |x| switch (b) {
                .uint => |y| std.math.order(x, y),
                .int => |y| std.math.order(@as(i128, x), @as(i128, y)),
                .float => |y| std.math.order(@as(f64, @floatFromInt(x)), y),
                else => null,
            },
            .float => |x| switch (b) {
                .float => |y| std.math.order(x, y),
                .int => |y| std.math.order(x, @as(f64, @floatFromInt(y))),
                .uint => |y| std.math.order(x, @as(f64, @floatFromInt(y))),
                else => null,
            },
            .string => |x| if (b == .string) std.mem.order(u8, x, b.string) else null,
        };
    }

    pub fn eql(a: Value, b: Value) bool {
        return (a.order(b) orelse return false) == .eq;
    }
};

pub fn isString(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .pointer) return false;
    const p = info.pointer;
    return switch (p.size) {
        .slice => p.child == u8,
        .one => switch (@typeInfo(p.child)) {
            .array => |a| a.child == u8,
            else => false,
        },
        else => false,
    };
}

pub fn toValue(v: anytype) Value {
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .null => return .null,
        .bool => return .{ .boolean = v },
        .int => |info| {
            if (info.bits > 64)
                @compileError("zom: " ++ @typeName(T) ++ " is wider than 64 bits; u128 support is planned for phase 6");
            if (info.signedness == .unsigned and info.bits == 64) return .{ .uint = v };
            return .{ .int = v };
        },
        .comptime_int => {
            if (comptime std.math.cast(i64, v) != null) return .{ .int = v };
            if (comptime std.math.cast(u64, v) != null) return .{ .uint = v };
            @compileError(std.fmt.comptimePrint("zom: {d} does not fit in 64 bits; u128 support is planned for phase 6", .{v}));
        },
        .float, .comptime_float => return .{ .float = v },
        .optional => return if (v) |inner| toValue(inner) else .null,
        .@"enum", .enum_literal => return .{ .string = @tagName(v) },
        .pointer => {
            if (comptime isString(T)) return .{ .string = v };
            @compileError("zom: unsupported pointer value type " ++ @typeName(T));
        },
        else => @compileError("zom: unsupported value type " ++ @typeName(T)),
    }
}

/// `error.ValueOutOfRange` when a runtime value does not fit the attribute,
/// e.g. a `u32` variable holding 300 set on a `u8` attribute.
pub fn fromValue(comptime F: type, v: Value) error{ValueOutOfRange}!F {
    switch (@typeInfo(F)) {
        .optional => |o| return if (v == .null) null else try fromValue(o.child, v),
        .bool => return v.boolean,
        .int => return switch (v) {
            .int => |i| std.math.cast(F, i) orelse error.ValueOutOfRange,
            .uint => |u| std.math.cast(F, u) orelse error.ValueOutOfRange,
            else => unreachable, // assertSettable rejects floats for int attributes
        },
        .float => return switch (v) {
            .float => |f| @floatCast(f),
            .int => |i| @floatFromInt(i),
            .uint => |u| @floatFromInt(u),
            else => unreachable,
        },
        .@"enum" => return std.meta.stringToEnum(F, v.string) orelse error.ValueOutOfRange,
        .pointer => return v.string,
        else => @compileError("zom: unsupported attribute type " ++ @typeName(F)),
    }
}

const Kind = enum { boolean, number, string, enumeration };

fn kindOf(comptime T: type, comptime name: []const u8) Kind {
    return switch (@typeInfo(T)) {
        .bool => .boolean,
        .int, .comptime_int, .float, .comptime_float => .number,
        .@"enum", .enum_literal => .enumeration,
        .optional => |o| kindOf(o.child, name),
        else => if (isString(T))
            .string
        else
            @compileError("zom: attribute '" ++ name ++ "' has unsupported type " ++ @typeName(T)),
    };
}

/// Compile-time guard used by `where` and `set`: a value must match the
/// attribute's type, and `null` is only allowed for optional attributes.
pub fn assertAssignable(comptime Field: type, comptime V: type, comptime name: []const u8) void {
    if (@typeInfo(V) == .null) {
        if (@typeInfo(Field) != .optional)
            @compileError("zom: attribute '" ++ name ++ "' is not optional, null is not allowed");
        return;
    }
    if (kindOf(Field, name) != kindOf(V, name))
        @compileError("zom: type mismatch on '" ++ name ++ "': attribute is " ++
            @typeName(Field) ++ ", got " ++ @typeName(V));
    const A = Base(Field);
    const B = Base(V);
    if (@typeInfo(A) == .@"enum" and @typeInfo(B) == .@"enum" and A != B)
        @compileError("zom: type mismatch on '" ++ name ++ "': attribute is " ++
            @typeName(A) ++ ", got " ++ @typeName(B));
}

/// `assertAssignable` plus what only matters when writing: a float cannot be
/// stored in an integer attribute.
pub fn assertSettable(comptime Field: type, comptime V: type, comptime name: []const u8) void {
    assertAssignable(Field, V, name);
    const b = @typeInfo(Base(V));
    if (@typeInfo(Base(Field)) == .int and (b == .float or b == .comptime_float))
        @compileError("zom: attribute '" ++ name ++ "' is " ++ @typeName(Field) ++
            ", a float (" ++ @typeName(V) ++ ") cannot be stored in it");
}

/// Checks on values that are always comptime-known: an enum literal must
/// name a tag of the attribute's enum, and an integer literal must fit.
pub fn assertLiteral(comptime Field: type, comptime value: anytype, comptime name: []const u8) void {
    const A = Base(Field);
    switch (@typeInfo(@TypeOf(value))) {
        .enum_literal => if (@typeInfo(A) == .@"enum" and !@hasField(A, @tagName(value)))
            @compileError("zom: '." ++ @tagName(value) ++ "' is not a value of " ++
                @typeName(A) ++ " (attribute '" ++ name ++ "')"),
        .comptime_int => if (@typeInfo(A) == .int and std.math.cast(A, value) == null)
            @compileError(std.fmt.comptimePrint("zom: {d} does not fit attribute '{s}' ({s})", .{
                value, name, @typeName(A),
            })),
        else => {},
    }
}

pub fn isComptimeOnly(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .enum_literal, .comptime_int, .comptime_float => true,
        else => false,
    };
}

fn Base(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

pub fn Query(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Tuple = T;
        pub const Field = std.meta.FieldEnum(T);
        /// Bounded on purpose (Tiger Style): no allocation to build a query.
        pub const max_filters = 16;
        /// Most values one `in` / `not_in` filter may hold. 64 covers lists
        /// written by hand and a page of keys (`combine` batches larger key
        /// sets), and keeps the worst case, `max_filters * max_in` = 1024
        /// bind parameters, far below every SQL driver's limit (SQLite
        /// 32766, Postgres 65535). Checked at compile time for a tuple and
        /// by assertion for a `whereIn` slice.
        pub const max_in = 64;

        pub const Filter = struct { field: Field, op: Op, operand: Operand };
        pub const Order = struct { field: Field, direction: Direction };
        pub const Change = struct { field: Field, value: Value };

        filters: [max_filters]Filter = undefined,
        filter_count: usize = 0,
        order: ?Order = null,
        limit: ?usize = null,
        offset: usize = 0,

        pub fn filterSlice(self: *const Self) []const Filter {
            return self.filters[0..self.filter_count];
        }

        /// Appends `f`. `eq null` and `neq null` are stored as `is_null` and
        /// `is_not_null`, so adapters only see one spelling of each.
        pub fn addFilter(self: *Self, f: Filter) void {
            std.debug.assert(self.filter_count < max_filters);
            std.debug.assert(f.operand == f.op.operand());
            if (f.operand == .many) std.debug.assert(f.operand.many.len <= max_in);
            self.filters[self.filter_count] = normalize(f);
            self.filter_count += 1;
        }

        fn normalize(f: Filter) Filter {
            if (f.operand != .one or f.operand.one != .null) return f;
            return switch (f.op) {
                .eq => .{ .field = f.field, .op = .is_null, .operand = .none },
                .neq => .{ .field = f.field, .op = .is_not_null, .operand = .none },
                else => f,
            };
        }

        // -- building ------------------------------------------------------

        /// A copy of this query with one more filter. Type-checked at
        /// compile time; what `value` must be depends on `op`:
        ///
        /// - `eq` .. `gte`: a value of the attribute's type. `null` (optional
        ///   attributes only) makes `eq` / `neq` an alias of `is_null` /
        ///   `is_not_null`; the ordering ops never match null.
        /// - `like`, `ilike`: a string pattern, on a string attribute.
        /// - `in`, `not_in`: a tuple of comptime-known values, at most
        ///   `max_in`, e.g. `.{ 1, 2, 3 }`. Use `whereIn` for a runtime slice.
        /// - `between`: a tuple `.{ lo, hi }`, both inclusive.
        /// - `is_null`, `is_not_null`: `{}`, on an optional attribute.
        ///
        /// String values are borrowed, not copied: they must outlive the query.
        pub fn where(self: Self, comptime field: Field, comptime op: Op, value: anytype) Self {
            var next = self;
            next.addFilter(filterFor(field, op, value));
            return next;
        }

        /// `where(field, .in, ...)` for a runtime slice (or pointer to an
        /// array) of attribute values, at most `max_in` long. The query
        /// borrows `values` without copying: the slice must stay alive and
        /// unchanged while this query, or a relation holding it, is used.
        pub fn whereIn(self: Self, comptime field: Field, values: anytype) Self {
            var next = self;
            next.addFilter(listFilter(field, .in, values));
            return next;
        }

        /// `whereIn` for `not_in`, with the same borrowing rule.
        pub fn whereNotIn(self: Self, comptime field: Field, values: anytype) Self {
            var next = self;
            next.addFilter(listFilter(field, .not_in, values));
            return next;
        }

        fn filterFor(comptime field: Field, comptime op: Op, value: anytype) Filter {
            const name = @tagName(field);
            const F = @FieldType(T, name);
            const V = @TypeOf(value);
            const op_name = "." ++ @tagName(op);
            const operand: Operand = switch (comptime op.operand()) {
                .one => blk: {
                    if (op == .like or op == .ilike) {
                        if (comptime !isString(Base(F)))
                            @compileError("zom: " ++ op_name ++ " needs a string attribute, '" ++ name ++
                                "' is " ++ @typeName(F));
                        if (comptime !isString(V))
                            @compileError("zom: " ++ op_name ++ " on '" ++ name ++
                                "' takes a string pattern, got " ++ @typeName(V));
                    }
                    checkValue(F, value, name);
                    break :blk .{ .one = toValue(value) };
                },
                .many => blk: {
                    const fields = comptime tupleFields(V, op_name, name, "a tuple of values, e.g. .{ 1, 2, 3 }; " ++
                        "use whereIn for a runtime slice");
                    if (fields.len > max_in)
                        @compileError(std.fmt.comptimePrint("zom: {s} on '{s}' has {d} values, more than max_in ({d})", .{
                            op_name, name, fields.len, max_in,
                        }));
                    inline for (fields) |f| {
                        if (!f.is_comptime)
                            @compileError("zom: " ++ op_name ++ " on '" ++ name ++ "': value " ++ f.name ++
                                " is not comptime-known; use whereIn for runtime values");
                        checkValue(F, @field(value, f.name), name);
                    }
                    // A static array: the filter can point at it forever.
                    const Static = struct {
                        const values: [fields.len]Value = v: {
                            var out: [fields.len]Value = undefined;
                            for (fields, &out) |f, *o| o.* = if (f.type == @TypeOf(null))
                                .null
                            else
                                toValue(f.defaultValue().?);
                            break :v out;
                        };
                    };
                    break :blk .{ .many = .of(Value, &Static.values) };
                },
                .range => blk: {
                    const fields = comptime tupleFields(V, op_name, name, "a tuple .{ lo, hi }");
                    if (fields.len != 2)
                        @compileError(std.fmt.comptimePrint("zom: {s} on '{s}' takes .{{ lo, hi }}, got {d} values", .{
                            op_name, name, fields.len,
                        }));
                    checkValue(F, value[0], name);
                    checkValue(F, value[1], name);
                    break :blk .{ .range = .{ toValue(value[0]), toValue(value[1]) } };
                },
                .none => blk: {
                    if (V != void)
                        @compileError("zom: " ++ op_name ++ " on '" ++ name ++ "' takes no value, pass {}, got " ++
                            @typeName(V));
                    if (@typeInfo(F) != .optional)
                        @compileError("zom: attribute '" ++ name ++ "' is not optional, " ++ op_name ++ " is not allowed");
                    break :blk .none;
                },
            };
            return .{ .field = field, .op = op, .operand = operand };
        }

        fn listFilter(comptime field: Field, comptime op: Op, values: anytype) Filter {
            const name = @tagName(field);
            const S = @TypeOf(values);
            const is_list = switch (@typeInfo(S)) {
                .pointer => |p| p.size == .slice or (p.size == .one and @typeInfo(p.child) == .array),
                else => false,
            };
            if (comptime !is_list or isString(S))
                @compileError("zom: whereIn on '" ++ name ++ "' takes a slice of values, got " ++ @typeName(S));
            const E = std.meta.Elem(S);
            comptime assertAssignable(@FieldType(T, name), E, name);
            const items: []const E = values;
            std.debug.assert(items.len <= max_in);
            return .{ .field = field, .op = op, .operand = .{ .many = .of(E, items) } };
        }

        fn tupleFields(
            comptime V: type,
            comptime op_name: []const u8,
            comptime name: []const u8,
            comptime want: []const u8,
        ) []const std.builtin.Type.StructField {
            const info = @typeInfo(V);
            if (info != .@"struct" or !info.@"struct".is_tuple)
                @compileError("zom: " ++ op_name ++ " on '" ++ name ++ "' takes " ++ want ++ ", got " ++ @typeName(V));
            return info.@"struct".fields;
        }

        /// `assertAssignable`, plus `assertLiteral` when the value is a literal.
        fn checkValue(comptime F: type, value: anytype, comptime name: []const u8) void {
            const V = @TypeOf(value);
            comptime assertAssignable(F, V, name);
            if (comptime isComptimeOnly(V)) comptime assertLiteral(F, value, name);
        }

        // -- evaluating ----------------------------------------------------

        pub fn fieldValue(row: T, field: Field) Value {
            return switch (field) {
                inline else => |tag| toValue(@field(row, @tagName(tag))),
            };
        }

        pub fn matches(self: *const Self, row: T) bool {
            for (self.filterSlice()) |f| {
                if (!filterMatches(f, row)) return false;
            }
            return true;
        }

        /// SQL's three-valued logic, with unknown counted as no match: a
        /// null attribute only matches `is_null`, and a null on the value
        /// side (`lt null`, `between .{ null, 3 }`) never matches. A null
        /// in an `in` list matches nothing, and makes `not_in` match nothing
        /// (`x NOT IN (1, NULL)` is never true). An empty `in` list matches
        /// nothing; an empty `not_in` list matches every non-null value.
        pub fn filterMatches(f: Filter, row: T) bool {
            const actual = fieldValue(row, f.field);
            switch (f.op) {
                .is_null => return actual == .null,
                .is_not_null => return actual != .null,
                else => if (actual == .null) return false,
            }
            switch (f.op) {
                .eq, .neq, .lt, .lte, .gt, .gte => {
                    const v = f.operand.one;
                    if (v == .null) return false;
                    const ord = compare(f.field, actual, v) orelse return false;
                    return switch (f.op) {
                        .eq => ord == .eq,
                        .neq => ord != .eq,
                        .lt => ord == .lt,
                        .lte => ord != .gt,
                        .gt => ord == .gt,
                        .gte => ord != .lt,
                        else => unreachable,
                    };
                },
                .in, .not_in => {
                    const list = f.operand.many;
                    var saw_null = false;
                    for (0..list.len) |i| {
                        const v = list.at(i);
                        if (v == .null) {
                            saw_null = true;
                            continue;
                        }
                        const ord = compare(f.field, actual, v) orelse continue;
                        if (ord == .eq) return f.op == .in;
                    }
                    return f.op == .not_in and !saw_null;
                },
                .between => {
                    const lo, const hi = f.operand.range;
                    if (lo == .null or hi == .null) return false;
                    const above = compare(f.field, actual, lo) orelse return false;
                    const below = compare(f.field, actual, hi) orelse return false;
                    return above != .lt and below != .gt;
                },
                .like, .ilike => {
                    const pattern = f.operand.one;
                    if (actual != .string or pattern != .string) return false;
                    return like(actual.string, pattern.string, if (f.op == .like) .sensitive else .insensitive);
                },
                .is_null, .is_not_null => unreachable,
            }
        }

        /// `Value.order`, except enum attributes compare in declaration order
        /// (as Postgres ENUMs do) rather than by tag name. Both values must
        /// be non-null.
        fn compare(field: Field, a: Value, b: Value) ?std.math.Order {
            switch (field) {
                inline else => |tag| {
                    const E = Base(@FieldType(T, @tagName(tag)));
                    if (comptime @typeInfo(E) != .@"enum") return a.order(b);
                    return std.math.order(@intFromEnum(toEnum(E, a)), @intFromEnum(toEnum(E, b)));
                },
            }
        }

        fn toEnum(comptime E: type, v: Value) E {
            const e = std.meta.stringToEnum(E, v.string);
            // assertAssignable only lets values of E reach this attribute,
            // so the tag name always resolves.
            std.debug.assert(e != null);
            return e.?;
        }

        pub fn lessThan(o: Order, a: T, b: T) bool {
            const x = fieldValue(a, o.field);
            const y = fieldValue(b, o.field);
            // Postgres default: null sorts above every value, so nulls come
            // last on asc and first on desc.
            const ord = if (x == .null or y == .null)
                std.math.order(@intFromBool(x == .null), @intFromBool(y == .null))
            else
                compare(o.field, x, y) orelse return false;
            return switch (o.direction) {
                .asc => ord == .lt,
                .desc => ord == .gt,
            };
        }
    };
}
