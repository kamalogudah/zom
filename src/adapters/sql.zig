//! SQL compiler: turns a relation's query into a parameterized statement.
//!
//! This is the half of rom-sql that does not need a driver. A Postgres
//! adapter would pair this with pg.zig: compile, bind `params`, map rows
//! back into the tuple type.

const std = @import("std");
const q = @import("../query.zig");
const Allocator = std.mem.Allocator;

pub const Compiled = struct {
    sql: []u8,
    params: []q.Value,

    pub fn deinit(self: Compiled, allocator: Allocator) void {
        allocator.free(self.sql);
        allocator.free(self.params);
    }
};

/// Writes `name` as a quoted identifier: wrapped in `"` with any `"` inside
/// doubled, so reserved words, mixed case and hostile names stay one name.
pub fn writeIdent(list: *std.ArrayList(u8), allocator: Allocator, name: []const u8) !void {
    try list.append(allocator, '"');
    for (name) |c| {
        if (c == '"') try list.append(allocator, '"');
        try list.append(allocator, c);
    }
    try list.append(allocator, '"');
}

/// What rendering a WHERE can fail with. Spelled out because `writeNode`
/// recurses, and a recursive function can't infer its error set.
pub const WhereError = Allocator.Error || error{ InvalidNullComparison, UnsupportedFilter };

/// Renders `nodes[index]`: a filter, a parenthesized `AND` / `OR` group, or
/// `NOT (...)`.
fn writeNode(
    comptime T: type,
    sql: *std.ArrayList(u8),
    params: *std.ArrayList(q.Value),
    allocator: Allocator,
    query: *const q.Query(T),
    index: u8,
) WhereError!void {
    switch (query.nodes[index]) {
        .filter => |f| try writeFilter(T, sql, params, allocator, query.filters[f]),
        .not => |child| {
            try sql.appendSlice(allocator, "NOT ");
            // A group brings its own parentheses.
            const bare = query.nodes[child] == .filter or query.nodes[child] == .not;
            if (bare) try sql.append(allocator, '(');
            try writeNode(T, sql, params, allocator, query, child);
            if (bare) try sql.append(allocator, ')');
        },
        .and_group, .or_group => |g| {
            const sep = if (query.nodes[index] == .and_group) " AND " else " OR ";
            try sql.append(allocator, '(');
            for (g.first..g.first + g.len) |c| {
                if (c > g.first) try sql.appendSlice(allocator, sep);
                try writeNode(T, sql, params, allocator, query, @intCast(c));
            }
            try sql.append(allocator, ')');
        },
    }
}

fn writeFilter(
    comptime T: type,
    sql: *std.ArrayList(u8),
    params: *std.ArrayList(q.Value),
    allocator: Allocator,
    f: q.Query(T).Filter,
) WhereError!void {
    try writeIdent(sql, allocator, @tagName(f.field));
    switch (f.op) {
        .is_null, .is_not_null => {
            try sql.append(allocator, ' ');
            try sql.appendSlice(allocator, f.op.sql());
        },
        .eq, .neq, .lt, .lte, .gt, .gte => {
            // eq/neq null were stored as is_null/is_not_null.
            if (f.operand.one == .null) return error.InvalidNullComparison;
            try sql.append(allocator, ' ');
            try sql.appendSlice(allocator, f.op.sql());
            try sql.print(allocator, " ${d}", .{params.items.len + 1});
            try params.append(allocator, f.operand.one);
        },
        // Rendering these needs a Dialect (ILIKE, empty IN lists, LIKE
        // escapes); it comes with zom-sql (#35).
        .in, .not_in, .like, .ilike, .between => return error.UnsupportedFilter,
    }
}

/// Postgres-style placeholders ($1, $2, ...). Column names come from the
/// tuple's field names; the table and every column are quoted.
pub fn compileSelect(comptime T: type, allocator: Allocator, table: []const u8, query: q.Query(T)) !Compiled {
    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(allocator);
    var params: std.ArrayList(q.Value) = .empty;
    errdefer params.deinit(allocator);

    try sql.appendSlice(allocator, "SELECT ");
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try writeIdent(&sql, allocator, f.name);
    }
    try sql.appendSlice(allocator, " FROM ");
    try writeIdent(&sql, allocator, table);

    var it = query.topNodes();
    var first = true;
    while (it.next()) |i| {
        try sql.appendSlice(allocator, if (first) " WHERE " else " AND ");
        first = false;
        try writeNode(T, &sql, &params, allocator, &query, @intCast(i));
    }

    if (query.order) |o| {
        try sql.appendSlice(allocator, " ORDER BY ");
        try writeIdent(&sql, allocator, @tagName(o.field));
        try sql.appendSlice(allocator, if (o.direction == .asc) " ASC" else " DESC");
    }
    if (query.limit) |l| try sql.print(allocator, " LIMIT {d}", .{l});
    if (query.offset > 0) try sql.print(allocator, " OFFSET {d}", .{query.offset});

    return .{ .sql = try sql.toOwnedSlice(allocator), .params = try params.toOwnedSlice(allocator) };
}
