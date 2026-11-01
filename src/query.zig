//! Adapter-agnostic query description.
//!
//! A relation never runs anything itself. It only builds up a `Query(T)`
//! value (filters, ordering, limit/offset). Each adapter decides what that
//! means: the memory adapter evaluates it against rows, zom-sql
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

// -- boolean groups ----------------------------------------------------------

/// What `Query.whereAny` and `Query.whereNot` take, and what nests inside
/// them: a condition is `.{ field, op, value }` (exactly what `where` takes,
/// with `field` and `op` comptime-known), or a group built by `any`, `all`
/// or `not`. Groups only carry their conditions; the query type-checks them
/// when they are added, against its own tuple type.
///
///     users.whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })
///     users.whereNot(zom.any(.{ .{ .age, .lt, 18 }, zom.all(.{ ... }) }))
pub const GroupKind = enum { all, any };

/// `conds`, OR-ed. A tuple of at least one condition.
pub fn any(conds: anytype) Group(.any, @TypeOf(conds)) {
    return .{ .conds = conds };
}

/// `conds`, AND-ed. A tuple of at least one condition. Only needed inside
/// `any` or `not`: at the top level, chain `where` instead.
pub fn all(conds: anytype) Group(.all, @TypeOf(conds)) {
    return .{ .conds = conds };
}

/// The negation of `cond`, with SQL's three-valued logic: see `Query.truth`.
pub fn not(cond: anytype) Not(@TypeOf(cond)) {
    return .{ .cond = cond };
}

pub fn Group(comptime kind: GroupKind, comptime C: type) type {
    return struct {
        pub const zom_group: GroupKind = kind;
        conds: C,
    };
}

pub fn Not(comptime C: type) type {
    return struct {
        pub const zom_not = {};
        cond: C,
    };
}

/// SQL's AND on TRUE / FALSE / UNKNOWN (`null`): false wins, then unknown.
pub fn and3(a: ?bool, b: ?bool) ?bool {
    if (a == false or b == false) return false;
    if (a == null or b == null) return null;
    return true;
}

/// SQL's OR on TRUE / FALSE / UNKNOWN (`null`): true wins, then unknown.
pub fn or3(a: ?bool, b: ?bool) ?bool {
    if (a == true or b == true) return true;
    if (a == null or b == null) return null;
    return false;
}

/// SQL's NOT: unknown stays unknown.
pub fn not3(a: ?bool) ?bool {
    return if (a) |b| !b else null;
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

        /// Most nodes (filters plus `any` / `all` / `not` groups) in one
        /// query. Every filter is a node, so this is at least `max_filters`.
        pub const max_nodes = 32;

        /// Most sort keys in one query: `ORDER BY a, b, c, d`.
        pub const max_orders = 4;

        pub const Filter = struct { field: Field, op: Op, operand: Operand };
        pub const Order = struct { field: Field, direction: Direction };
        pub const Change = struct { field: Field, value: Value };

        /// The filter tree, stored flat so that copying a query copies the
        /// whole tree: nodes refer to each other by index into `nodes`, and
        /// to their filter by index into `filters`, never by pointer.
        pub const Node = union(enum) {
            /// Index into `filters`.
            filter: u8,
            /// Children AND-ed: `nodes[first..][0..len]`.
            and_group: Children,
            /// Children OR-ed: `nodes[first..][0..len]`.
            or_group: Children,
            /// Index into `nodes` of the negated child.
            not: u8,
        };
        /// A group's children are contiguous; their own children come after
        /// all of them.
        pub const Children = struct { first: u8, len: u8 };

        /// Every filter, top-level or inside a group, in the order added.
        filters: [max_filters]Filter = undefined,
        filter_count: usize = 0,
        nodes: [max_nodes]Node = undefined,
        node_count: u8 = 0,
        /// The nodes the query AND-s together; the others sit in a group.
        top: std.StaticBitSet(max_nodes) = .initEmpty(),
        /// Sort keys, most significant first: `orders[1]` breaks ties on
        /// `orders[0]`, and so on. Read through `orderSlice()`.
        orders: [max_orders]Order = undefined,
        order_count: u8 = 0,
        limit: ?usize = null,
        offset: usize = 0,
        /// Set to say an update or delete with no filters is meant to touch
        /// every row. It changes nothing about which rows match; it only
        /// lifts the safety check of compilers such as zom-sql, which
        /// refuse an unfiltered `UPDATE` / `DELETE` (`error.UnboundedWrite`)
        /// unless this is true. The memory adapter does not look at it.
        all: bool = false,

        /// The filters of a query that has no `any` / `not` groups, which
        /// are then all AND-ed. An adapter that does not support `or` reads
        /// the query through this; one that does walks `nodeSlice()` from
        /// `topNodes()` instead. Asserts `isConjunction()`.
        pub fn filterSlice(self: *const Self) []const Filter {
            std.debug.assert(self.isConjunction());
            return self.filters[0..self.filter_count];
        }

        /// The sort keys, most significant first. Empty: no order.
        pub fn orderSlice(self: *const Self) []const Order {
            return self.orders[0..self.order_count];
        }

        /// Appends `o` as the least significant sort key. Panics, naming the
        /// limit, past `max_orders`.
        pub fn addOrder(self: *Self, o: Order) void {
            if (self.order_count >= max_orders)
                std.debug.panic("zom: query has more than max_orders ({d}) orders", .{max_orders});
            self.orders[self.order_count] = o;
            self.order_count += 1;
        }

        /// A copy of this query also sorted by `field`, after the keys it
        /// already has: `.order(.a, .asc).order(.b, .desc)` is `ORDER BY a
        /// ASC, b DESC`. Past `max_orders` keys, panics.
        pub fn order(self: Self, comptime field: Field, direction: Direction) Self {
            var next = self;
            next.addOrder(.{ .field = field, .direction = direction });
            return next;
        }

        /// A copy of this query with its sort keys replaced by `keys`, a
        /// tuple of `.{ field, direction }` pairs with `field`
        /// comptime-known: `reorder(.{ .{ .role, .asc }, .{ .age, .desc } })`.
        /// `reorder(.{})` removes the order. More than `max_orders` keys is
        /// a compile error.
        pub fn reorder(self: Self, keys: anytype) Self {
            const K = @TypeOf(keys);
            const info = @typeInfo(K);
            if (info != .@"struct" or !info.@"struct".is_tuple)
                @compileError("zom: reorder takes a tuple of .{ field, direction } pairs, e.g. .{ .{ .age, .desc } }, got " ++ @typeName(K));
            const fields = info.@"struct".fields;
            if (fields.len > max_orders)
                @compileError(std.fmt.comptimePrint("zom: reorder has {d} keys, more than max_orders ({d})", .{ fields.len, max_orders }));
            var next = self;
            next.order_count = 0;
            inline for (fields) |f| {
                const key = @field(keys, f.name);
                const P = @TypeOf(key);
                const pinfo = @typeInfo(P);
                if (pinfo != .@"struct" or !pinfo.@"struct".is_tuple or pinfo.@"struct".fields.len != 2)
                    @compileError("zom: a reorder key is .{ field, direction }, e.g. .{ .age, .desc }, got " ++ @typeName(P));
                if (!pinfo.@"struct".fields[0].is_comptime)
                    @compileError("zom: a reorder key's field must be comptime-known, e.g. .{ .age, .desc }");
                next.addOrder(.{ .field = comptime key[0], .direction = key[1] });
            }
            return next;
        }

        /// True when every node is a top-level filter (no groups), so the
        /// query is `filterSlice()` AND-ed.
        pub fn isConjunction(self: *const Self) bool {
            return self.node_count == self.filter_count;
        }

        pub fn nodeSlice(self: *const Self) []const Node {
            return self.nodes[0..self.node_count];
        }

        /// The indices into `nodeSlice()` of the nodes the query AND-s, in
        /// the order they were added.
        pub fn topNodes(self: *const Self) std.StaticBitSet(max_nodes).Iterator(.{}) {
            return self.top.iterator(.{});
        }

        /// Appends `f` as a top-level (AND-ed) filter. `eq null` and `neq
        /// null` are stored as `is_null` and `is_not_null`, so adapters only
        /// see one spelling of each.
        pub fn addFilter(self: *Self, f: Filter) void {
            self.reserve(1, 1);
            const slot = self.node_count;
            self.node_count += 1;
            self.top.set(slot);
            self.nodes[slot] = .{ .filter = self.pushFilter(f) };
        }

        fn pushFilter(self: *Self, f: Filter) u8 {
            std.debug.assert(self.filter_count < max_filters);
            std.debug.assert(f.operand == f.op.operand());
            if (f.operand == .many) std.debug.assert(f.operand.many.len <= max_in);
            const index: u8 = @intCast(self.filter_count);
            self.filters[index] = normalize(f);
            self.filter_count += 1;
            return index;
        }

        /// Panics, naming the limit, unless `nodes` more nodes holding
        /// `filters` more filters fit.
        fn reserve(self: *const Self, nodes: usize, filters: usize) void {
            if (self.filter_count + filters > max_filters)
                std.debug.panic("zom: query has more than max_filters ({d}) filters", .{max_filters});
            if (@as(usize, self.node_count) + nodes > max_nodes)
                std.debug.panic("zom: query has more than max_nodes ({d}) nodes (filters plus any/all/not groups)", .{max_nodes});
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

        /// A copy of this query AND-ed with `conds` OR-ed together, e.g.
        /// `whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })`.
        /// Each condition is `.{ field, op, value }`, type-checked like
        /// `where` (a runtime slice works for `in` / `not_in`, borrowed as
        /// by `whereIn`), or a nested `zom.any`, `zom.all` or `zom.not`.
        pub fn whereAny(self: Self, conds: anytype) Self {
            var next = self;
            next.addCond(any(conds));
            return next;
        }

        /// A copy of this query AND-ed with NOT `cond`, e.g.
        /// `whereNot(.{ .age, .gt, 30 })` or `whereNot(zom.any(.{ ... }))`.
        /// SQL's three-valued logic applies, so a row where `cond` is
        /// unknown (`NULL > 30`) matches neither `cond` nor its negation.
        pub fn whereNot(self: Self, cond: anytype) Self {
            var next = self;
            next.addCond(not(cond));
            return next;
        }

        /// Appends `cond` (see `whereAny`) as a top-level node. A condition
        /// too big for an empty query is a compile error; one that does not
        /// fit the space left panics.
        pub fn addCond(self: *Self, cond: anytype) void {
            const size = comptime condSize(@TypeOf(cond));
            if (size.filters > max_filters)
                @compileError(std.fmt.comptimePrint("zom: condition has {d} filters, more than max_filters ({d})", .{
                    size.filters, max_filters,
                }));
            if (size.nodes > max_nodes)
                @compileError(std.fmt.comptimePrint("zom: condition has {d} nodes (filters plus any/all/not groups), more than max_nodes ({d})", .{
                    size.nodes, max_nodes,
                }));
            self.reserve(size.nodes, size.filters);
            const slot = self.node_count;
            self.node_count += 1;
            self.top.set(slot);
            self.writeCond(slot, cond);
        }

        /// Appends node `index` of `src`, with everything under it, as a
        /// top-level (AND-ed) node of this query. Splitting a query into two
        /// is a loop over `src.topNodes()` calling this on one or the other;
        /// nothing is allocated. Panics, like `addCond`, if it does not fit.
        pub fn addNodeFrom(self: *Self, src: *const Self, index: u8) void {
            const size = src.nodeSize(index);
            self.reserve(size.nodes, size.filters);
            const slot = self.node_count;
            self.node_count += 1;
            self.top.set(slot);
            self.copyNode(slot, src, index);
        }

        /// The nodes and filters in the subtree at `index`, itself included.
        fn nodeSize(self: *const Self, index: u8) Size {
            return switch (self.nodes[index]) {
                .filter => .{ .nodes = 1, .filters = 1 },
                .not => |child| blk: {
                    const s = self.nodeSize(child);
                    break :blk .{ .nodes = 1 + s.nodes, .filters = s.filters };
                },
                .and_group, .or_group => |g| blk: {
                    var size: Size = .{ .nodes = 1, .filters = 0 };
                    for (g.first..g.first + g.len) |c| {
                        const s = self.nodeSize(@intCast(c));
                        size.nodes += s.nodes;
                        size.filters += s.filters;
                    }
                    break :blk size;
                },
            };
        }

        /// `writeCond` for a node of another query: writes `src.nodes[index]`
        /// into `nodes[slot]`, which the caller reserved, re-indexing its
        /// children the same way.
        fn copyNode(self: *Self, slot: u8, src: *const Self, index: u8) void {
            switch (src.nodes[index]) {
                .filter => |f| self.nodes[slot] = .{ .filter = self.pushFilter(src.filters[f]) },
                .not => |child| {
                    const copy = self.node_count;
                    self.node_count += 1;
                    self.nodes[slot] = .{ .not = copy };
                    self.copyNode(copy, src, child);
                },
                .and_group, .or_group => |g| {
                    const children: Children = .{ .first = self.node_count, .len = g.len };
                    self.node_count += g.len;
                    self.nodes[slot] = if (src.nodes[index] == .and_group)
                        .{ .and_group = children }
                    else
                        .{ .or_group = children };
                    for (0..g.len) |k| self.copyNode(@intCast(children.first + k), src, @intCast(g.first + k));
                },
            }
        }

        const Size = struct { nodes: usize, filters: usize };

        fn condSize(comptime C: type) Size {
            if (comptime groupKind(C) != null) {
                const fields = groupFields(C);
                var size: Size = .{ .nodes = 1, .filters = 0 };
                for (fields) |f| {
                    const child = condSize(f.type);
                    size.nodes += child.nodes;
                    size.filters += child.filters;
                }
                return size;
            }
            if (comptime isNot(C)) {
                const child = condSize(@FieldType(C, "cond"));
                return .{ .nodes = 1 + child.nodes, .filters = child.filters };
            }
            return .{ .nodes = 1, .filters = 1 };
        }

        fn groupKind(comptime C: type) ?GroupKind {
            return if (@typeInfo(C) == .@"struct" and @hasDecl(C, "zom_group")) C.zom_group else null;
        }

        fn isNot(comptime C: type) bool {
            return @typeInfo(C) == .@"struct" and @hasDecl(C, "zom_not");
        }

        fn groupFields(comptime C: type) []const std.builtin.Type.StructField {
            const name = "zom." ++ @tagName(C.zom_group);
            const Conds = @FieldType(C, "conds");
            const info = @typeInfo(Conds);
            if (info != .@"struct" or !info.@"struct".is_tuple)
                @compileError("zom: " ++ name ++ " takes a tuple of conditions, e.g. .{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } }, got " ++
                    @typeName(Conds));
            if (info.@"struct".fields.len == 0)
                @compileError("zom: " ++ name ++ " needs at least one condition");
            return info.@"struct".fields;
        }

        /// Writes `cond` into `nodes[slot]`, which the caller reserved.
        /// A group takes the next `len` slots for its children, then each
        /// child appends its own children after those.
        fn writeCond(self: *Self, slot: u8, cond: anytype) void {
            const C = @TypeOf(cond);
            if (comptime groupKind(C)) |kind| {
                const fields = comptime groupFields(C);
                const children: Children = .{ .first = self.node_count, .len = fields.len };
                self.node_count += fields.len;
                self.nodes[slot] = switch (kind) {
                    .all => .{ .and_group = children },
                    .any => .{ .or_group = children },
                };
                inline for (fields, 0..) |f, k| self.writeCond(@intCast(children.first + k), @field(cond.conds, f.name));
            } else if (comptime isNot(C)) {
                const child = self.node_count;
                self.node_count += 1;
                self.nodes[slot] = .{ .not = child };
                self.writeCond(child, cond.cond);
            } else {
                self.nodes[slot] = .{ .filter = self.pushFilter(leafFilter(cond)) };
            }
        }

        /// `.{ field, op, value }` to a filter, with `where`'s checks.
        fn leafFilter(cond: anytype) Filter {
            const C = @TypeOf(cond);
            const info = @typeInfo(C);
            if (info != .@"struct" or !info.@"struct".is_tuple or info.@"struct".fields.len != 3)
                @compileError("zom: a condition is .{ field, op, value }, zom.any(...), zom.all(...) or zom.not(...), got " ++
                    @typeName(C));
            const fields = info.@"struct".fields;
            if (!fields[0].is_comptime or !fields[1].is_comptime)
                @compileError("zom: a condition's field and op must be comptime-known, e.g. .{ .age, .gt, 30 }");
            const field: Field = comptime cond[0];
            const op: Op = comptime cond[1];
            const V = @TypeOf(cond[2]);
            if (comptime op.operand() == .many and @typeInfo(V) == .pointer)
                return listFilter(field, op, cond[2]);
            return filterFor(field, op, cond[2]);
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

        /// True when the query's WHERE is true for `row`, as SQL decides
        /// which rows a query returns: unknown is not a match.
        pub fn matches(self: *const Self, row: T) bool {
            return self.truth(row) == true;
        }

        /// The query's WHERE for `row` in SQL's three-valued logic: true,
        /// false, or `null` for unknown. A comparison with null is unknown
        /// (see `filterTruth`), AND / OR follow `and3` / `or3`, and NOT
        /// keeps unknown unknown: `NOT (age > 30)` is unknown, so not a
        /// match, for a row whose age is null, just like `age > 30`.
        pub fn truth(self: *const Self, row: T) ?bool {
            var result: ?bool = true;
            var it = self.topNodes();
            while (it.next()) |i| {
                result = and3(result, self.nodeTruth(@intCast(i), row));
                if (result == false) return false;
            }
            return result;
        }

        /// One node of `nodeSlice()`, evaluated like `truth`. Recursion is
        /// bounded: a node's children always have higher indices, so the
        /// depth is below `max_nodes`.
        pub fn nodeTruth(self: *const Self, index: u8, row: T) ?bool {
            switch (self.nodes[index]) {
                .filter => |f| return filterTruth(self.filters[f], row),
                .not => |child| return not3(self.nodeTruth(child, row)),
                .and_group => |g| {
                    var result: ?bool = true;
                    for (g.first..g.first + g.len) |c| {
                        result = and3(result, self.nodeTruth(@intCast(c), row));
                        if (result == false) return false;
                    }
                    return result;
                },
                .or_group => |g| {
                    var result: ?bool = false;
                    for (g.first..g.first + g.len) |c| {
                        result = or3(result, self.nodeTruth(@intCast(c), row));
                        if (result == true) return true;
                    }
                    return result;
                },
            }
        }

        /// `filterTruth`, with unknown counted as no match.
        pub fn filterMatches(f: Filter, row: T) bool {
            return filterTruth(f, row) == true;
        }

        /// One filter in SQL's three-valued logic (`null` is unknown). A
        /// null attribute is only known to `is_null` / `is_not_null`, and a
        /// null on the value side (`lt null`) is unknown. `in` is true on a
        /// match, else unknown when the list holds a null, else false;
        /// `not_in` is its negation, so `x NOT IN (1, NULL)` is false for
        /// 1 and unknown otherwise, never true. An empty `in` list is false;
        /// an empty `not_in` list is true for every non-null value.
        /// `between .{ lo, hi }` is `x >= lo AND x <= hi`, so `between .{
        /// null, 3 }` is false for 5 and unknown for 2.
        pub fn filterTruth(f: Filter, row: T) ?bool {
            const actual = fieldValue(row, f.field);
            switch (f.op) {
                .is_null => return actual == .null,
                .is_not_null => return actual != .null,
                else => if (actual == .null) return null,
            }
            switch (f.op) {
                .eq, .neq, .lt, .lte, .gt, .gte => {
                    const v = f.operand.one;
                    if (v == .null) return null;
                    const ord = compare(f.field, actual, v) orelse return null;
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
                    if (saw_null) return null;
                    return f.op == .not_in;
                },
                .between => {
                    const lo, const hi = f.operand.range;
                    const above: ?bool = if (lo == .null) null else if (compare(f.field, actual, lo)) |o| o != .lt else null;
                    const below: ?bool = if (hi == .null) null else if (compare(f.field, actual, hi)) |o| o != .gt else null;
                    return and3(above, below);
                },
                .like, .ilike => {
                    const pattern = f.operand.one;
                    if (actual != .string or pattern != .string) return null;
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

        /// `a` against `b` on one sort key, direction applied. Nulls sort
        /// as Postgres does by default, above every value: last on asc,
        /// first on desc. Two nulls, or two values that do not compare, are
        /// `.eq`, so the next key decides.
        pub fn orderBy(o: Order, a: T, b: T) std.math.Order {
            const x = fieldValue(a, o.field);
            const y = fieldValue(b, o.field);
            const ord = if (x == .null or y == .null)
                std.math.order(@intFromBool(x == .null), @intFromBool(y == .null))
            else
                compare(o.field, x, y) orelse .eq;
            return switch (o.direction) {
                .asc => ord,
                .desc => ord.invert(),
            };
        }

        /// The comparator for `std.mem.sort(T, rows, query.orderSlice(),
        /// lessThan)`: compares key by key, moving to the next key on a tie.
        /// Rows equal on every key are not less than each other, so a
        /// stable sort keeps them in the order it was given them.
        pub fn lessThan(orders: []const Order, a: T, b: T) bool {
            for (orders) |o| {
                switch (orderBy(o, a, b)) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
            }
            return false;
        }
    };
}
