const std = @import("std");
const zom = @import("zom");
const infer = @import("infer.zig");
const testing = std.testing;

const int = infer.Type{ .int = .{ .signedness = .signed, .bits = 32 } };
const bigint = infer.Type{ .int = .{ .signedness = .signed, .bits = 64 } };

/// Exercises quoting, enums, nullable fields, skipped columns and every
/// reason a table gets no schema. `testdata/infer_golden.zig` is the
/// expected output, and is imported below, so it must also compile.
const catalog: infer.Catalog = .{
    .schema = "public",
    .enums = &.{
        .{ .name = "user_role", .labels = &.{ "admin", "member", "in progress", "null", "_" } },
    },
    .tables = &.{
        .{
            .name = "users",
            .primary_key = &.{"id"},
            .columns = &.{
                .{ .name = "id", .type = int, .sql_type = "integer", .nullable = false },
                .{ .name = "name", .type = .string, .sql_type = "text", .nullable = false },
                .{ .name = "role", .type = .{ .@"enum" = "user_role" }, .sql_type = "user_role", .nullable = false },
                .{ .name = "score", .type = .{ .float = 64 }, .sql_type = "double precision", .nullable = true },
                .{ .name = "active", .type = .bool, .sql_type = "boolean", .nullable = false },
                .{ .name = "deleted_at", .type = bigint, .sql_type = "bigint", .nullable = true },
                .{ .name = "created_at", .type = null, .sql_type = "timestamp with time zone", .nullable = false },
            },
        },
        .{
            .name = "2fa codes",
            .primary_key = &.{"user id"},
            .columns = &.{
                .{ .name = "user id", .type = int, .sql_type = "integer", .nullable = false },
                .{ .name = "type", .type = .string, .sql_type = "text", .nullable = false },
                .{ .name = "u8", .type = .{ .int = .{ .signedness = .signed, .bits = 16 } }, .sql_type = "smallint", .nullable = false },
            },
        },
        .{
            .name = "events",
            .primary_key = &.{},
            .columns = &.{.{ .name = "body", .type = .string, .sql_type = "text", .nullable = true }},
        },
        .{
            .name = "memberships",
            .primary_key = &.{ "user_id", "group_id" },
            .columns = &.{
                .{ .name = "user_id", .type = int, .sql_type = "integer", .nullable = false },
                .{ .name = "group_id", .type = int, .sql_type = "integer", .nullable = false },
            },
        },
        .{
            .name = "sessions",
            .primary_key = &.{"token"},
            .columns = &.{.{ .name = "token", .type = null, .sql_type = "uuid", .nullable = false }},
        },
    },
};

test "render matches testdata/infer_golden.zig" {
    const source = try infer.render(testing.allocator, catalog, .{});
    defer testing.allocator.free(source);
    try testing.expectEqualStrings(@embedFile("testdata/infer_golden.zig"), source);
}

test "the generated schemas are usable zom schemas" {
    const g = @import("testdata/infer_golden.zig");
    try testing.expectEqualStrings("users", g.UsersSchema.name);
    try testing.expectEqual(.id, g.UsersSchema.primary_key);
    try testing.expectEqualStrings("2fa codes", g.@"2faCodesSchema".name);
    try testing.expectEqualStrings("user id", @tagName(g.@"2faCodesSchema".primary_key));
    try testing.expectEqualStrings("in progress", @tagName(g.UserRole.@"in progress"));

    const u: g.Users = .{ .id = 1, .name = "ada", .role = .admin, .active = true };
    try testing.expectEqual(null, u.score);
    try testing.expectEqual(null, u.deleted_at);
    try testing.expect(!@hasField(g.Users, "created_at"));
    try testing.expect(!@hasDecl(g, "EventsSchema"));
    try testing.expect(!@hasDecl(g, "MembershipsSchema"));
    try testing.expect(!@hasDecl(g, "SessionsSchema"));

    var memory = zom.memory.Gateway.init(testing.allocator, .{});
    defer memory.deinit();
    const users = try zom.Relation(g.UsersSchema, zom.memory.Gateway).init(&memory);
    _ = try users.create(u).commit();
    try testing.expectEqual(1, try users.count());
}

test "a table and another table's schema with the same Zig name collide" {
    const c: infer.Catalog = .{ .schema = "public", .tables = &.{
        .{ .name = "users", .primary_key = &.{"id"}, .columns = &.{.{ .name = "id", .type = int, .sql_type = "integer", .nullable = false }} },
        .{ .name = "users_schema", .primary_key = &.{}, .columns = &.{} },
    } };
    const collision = (try infer.findCollision(testing.allocator, c)).?;
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "the schema of table \"users\" and table \"users_schema\" both become UsersSchema",
        try std.fmt.bufPrint(&buf, "{f}", .{collision}),
    );
    try testing.expectError(error.NameCollision, infer.render(testing.allocator, c, .{}));
}

test "a table without a primary key leaves its schema name free" {
    const c: infer.Catalog = .{ .schema = "public", .tables = &.{
        .{ .name = "users", .primary_key = &.{}, .columns = &.{} },
        .{ .name = "users_schema", .primary_key = &.{}, .columns = &.{} },
    } };
    try testing.expectEqual(null, try infer.findCollision(testing.allocator, c));
}

test "an enum column needs its enum in the catalog" {
    const c: infer.Catalog = .{ .schema = "public", .tables = &.{
        .{ .name = "t", .primary_key = &.{}, .columns = &.{.{ .name = "r", .type = .{ .@"enum" = "role" }, .sql_type = "role", .nullable = false }} },
    } };
    try testing.expectError(error.UnknownEnum, infer.render(testing.allocator, c, .{}));
}

test "an empty catalog renders just the header" {
    const source = try infer.render(testing.allocator, .{ .schema = "app", .tables = &.{} }, .{ .zom_import = "orm" });
    defer testing.allocator.free(source);
    try testing.expectEqualStrings(
        \\// generated by zom-sql infer from schema "app"; do not edit
        \\
        \\const orm = @import("orm");
        \\
    , source);
}
