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

    pub fn sql(op: Op) []const u8 {
        return switch (op) {
            .eq => "=",
            .neq => "<>",
            .lt => "<",
            .lte => "<=",
            .gt => ">",
            .gte => ">=",
        };
    }
};

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

        pub const Filter = struct { field: Field, op: Op, value: Value };
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

        pub fn addFilter(self: *Self, f: Filter) void {
            std.debug.assert(self.filter_count < max_filters);
            self.filters[self.filter_count] = f;
            self.filter_count += 1;
        }

        pub fn fieldValue(row: T, field: Field) Value {
            return switch (field) {
                inline else => |tag| toValue(@field(row, @tagName(tag))),
            };
        }

        pub fn matches(self: *const Self, row: T) bool {
            for (self.filterSlice()) |f| {
                const actual = fieldValue(row, f.field);
                // Null filters follow SQL: eq is IS NULL, neq is IS NOT NULL,
                // ordering comparisons against null never match.
                if (f.value == .null or actual == .null) {
                    const both_null = f.value == .null and actual == .null;
                    const ok = switch (f.op) {
                        .eq => both_null,
                        .neq => f.value == .null and actual != .null,
                        else => false,
                    };
                    if (!ok) return false;
                    continue;
                }
                const ord = compare(f.field, actual, f.value) orelse return false;
                const ok = switch (f.op) {
                    .eq => ord == .eq,
                    .neq => ord != .eq,
                    .lt => ord == .lt,
                    .lte => ord != .gt,
                    .gt => ord == .gt,
                    .gte => ord != .lt,
                };
                if (!ok) return false;
            }
            return true;
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
