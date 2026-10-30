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

/// Postgres-style placeholders ($1, $2, ...). Column names come from the
/// tuple's field names.
pub fn compileSelect(comptime T: type, allocator: Allocator, table: []const u8, query: q.Query(T)) !Compiled {
    var sql: std.ArrayList(u8) = .empty;
    errdefer sql.deinit(allocator);
    var params: std.ArrayList(q.Value) = .empty;
    errdefer params.deinit(allocator);

    try sql.appendSlice(allocator, "SELECT ");
    inline for (@typeInfo(T).@"struct".fields, 0..) |f, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.appendSlice(allocator, f.name);
    }
    try sql.appendSlice(allocator, " FROM ");
    try sql.appendSlice(allocator, table);

    for (query.filterSlice(), 0..) |f, i| {
        try sql.appendSlice(allocator, if (i == 0) " WHERE " else " AND ");
        try sql.appendSlice(allocator, @tagName(f.field));
        if (f.value == .null) {
            try sql.appendSlice(allocator, switch (f.op) {
                .eq => " IS NULL",
                .neq => " IS NOT NULL",
                else => return error.InvalidNullComparison,
            });
            continue;
        }
        try sql.append(allocator, ' ');
        try sql.appendSlice(allocator, f.op.sql());
        try sql.print(allocator, " ${d}", .{params.items.len + 1});
        try params.append(allocator, f.value);
    }

    if (query.order) |o| {
        try sql.appendSlice(allocator, " ORDER BY ");
        try sql.appendSlice(allocator, @tagName(o.field));
        try sql.appendSlice(allocator, if (o.direction == .asc) " ASC" else " DESC");
    }
    if (query.limit) |l| try sql.print(allocator, " LIMIT {d}", .{l});
    if (query.offset > 0) try sql.print(allocator, " OFFSET {d}", .{query.offset});

    return .{ .sql = try sql.toOwnedSlice(allocator), .params = try params.toOwnedSlice(allocator) };
}
