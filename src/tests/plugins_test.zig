const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const Note = struct {
    id: u32,
    title: []const u8,
    created_at: i64 = 0,
    updated_at: i64 = 0,
};
const NoteSchema = zom.Schema(Note, "notes", .id, .{
    .plugins = .{zom.plugins.timestamps(.{ .created = .created_at, .updated = .updated_at })},
});
const Notes = zom.Relation(NoteSchema, zom.memory.Gateway);

const t0: i64 = 1_700_000_000 * std.time.ns_per_s;
const t1: i64 = t0 + 60 * std.time.ns_per_s;

fn notes(gw: *zom.memory.Gateway, now: i64) !Notes {
    return (try Notes.init(gw)).withPluginContext(.{ .clock = .{ .fixed = now } });
}

test "timestamps: create sets both fields from the clock" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try notes(&gw, t0);

    // Whatever the tuple held is overwritten.
    const stored = try rel.create(.{ .id = 1, .title = "a", .created_at = 5, .updated_at = 5 }).commit();
    try testing.expectEqual(t0, stored.created_at);
    try testing.expectEqual(t0, stored.updated_at);

    const back = (try rel.byPk(1).one(testing.allocator)).?;
    try testing.expectEqual(t0, back.created_at);
    try testing.expectEqual(t0, back.updated_at);
}

test "timestamps: update sets updated_at and leaves created_at" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    _ = try (try notes(&gw, t0)).create(.{ .id = 1, .title = "a" }).commit();

    const later = try notes(&gw, t1);
    try testing.expectEqual(@as(usize, 1), try later.byPk(1).update().set(.title, "b").commit());

    const back = (try later.byPk(1).one(testing.allocator)).?;
    try testing.expectEqualStrings("b", back.title);
    try testing.expectEqual(t0, back.created_at);
    try testing.expectEqual(t1, back.updated_at);
}

test "timestamps: an explicit updated_at wins, and an empty update touches nothing" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try notes(&gw, t1);
    _ = try rel.create(.{ .id = 1, .title = "a" }).commit();

    _ = try rel.byPk(1).update().set(.updated_at, 42).commit();
    try testing.expectEqual(@as(i64, 42), (try rel.byPk(1).one(testing.allocator)).?.updated_at);

    try testing.expectEqual(@as(usize, 0), try rel.byPk(1).update().commit());
    try testing.expectEqual(@as(i64, 42), (try rel.byPk(1).one(testing.allocator)).?.updated_at);
}

test "timestamps: the updated_at change counts towards max_changes" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try notes(&gw, t0);
    _ = try rel.create(.{ .id = 1, .title = "a" }).commit();

    var u = rel.byPk(1).update();
    for (0..zom.plugins.max_changes) |_| u = u.set(.title, "b");
    try testing.expectError(error.TooManyChanges, u.commit());
    try testing.expectEqualStrings("a", (try rel.byPk(1).one(testing.allocator)).?.title);

    // One fewer leaves room for it.
    var v = rel.byPk(1).update();
    for (0..zom.plugins.max_changes - 1) |_| v = v.set(.title, "c");
    try testing.expectEqual(@as(usize, 1), try v.commit());
}

test "timestamps: createMany sets them on a copy, with commitAlloc" {
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try notes(&gw, t0);

    const rows = [_]Note{ .{ .id = 1, .title = "a" }, .{ .id = 2, .title = "b" } };
    try testing.expectEqual(@as(usize, 2), try rel.createMany(&rows).commitAlloc(testing.allocator));
    try testing.expectEqual(@as(i64, 0), rows[0].created_at);

    const all = try rel.order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(all);
    for (all) |n| {
        try testing.expectEqual(t0, n.created_at);
        try testing.expectEqual(t0, n.updated_at);
    }
}

test "timestamps: other units, one field, and a clock that advances" {
    const Event = struct { id: u32, at: i64 };
    const EventSchema = zom.Schema(Event, "events", .id, .{
        .plugins = .{zom.plugins.timestamps(.{ .created = null, .updated = .at, .unit = .seconds })},
    });
    const Events = zom.Relation(EventSchema, zom.memory.Gateway);

    const Ticker = struct {
        ns: i64,
        fn now(ctx: ?*anyopaque) i64 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            defer self.ns += std.time.ns_per_s;
            return self.ns;
        }
    };
    var ticker: Ticker = .{ .ns = t0 };

    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = (try Events.init(&gw)).withPluginContext(.{ .clock = .{ .func = .{ .ctx = &ticker, .now = Ticker.now } } });

    try testing.expectEqual(@as(i64, 1_700_000_000), (try rel.create(.{ .id = 1, .at = 0 }).commit()).at);
    _ = try rel.byPk(1).update().set(.id, 1).commit();
    try testing.expectEqual(@as(i64, 1_700_000_001), (try rel.byPk(1).one(testing.allocator)).?.at);
}

test "timestamps: associated creates, select and allowFallback keep the context" {
    const User = struct { id: u32 };
    const Comment = struct { id: u32, user_id: u32, created_at: i64 = 0, updated_at: i64 = 0 };
    const UserSchema = zom.Schema(User, "users", .id, .{});
    const CommentSchema = zom.Schema(Comment, "comments", .id, .{
        .associations = .{ .author = zom.belongsTo(UserSchema, .user_id) },
        .plugins = .{zom.plugins.timestamps(.{})},
    });
    const Comments = zom.Relation(CommentSchema, zom.memory.Gateway);

    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = (try Comments.init(&gw)).withPluginContext(.{ .clock = .{ .fixed = t0 } });

    const c = try rel.associate(.author, User{ .id = 7 }).create(.{ .id = 1 }).commit();
    try testing.expectEqual(@as(u32, 7), c.user_id);
    try testing.expectEqual(t0, c.created_at);

    try testing.expectEqual(t0, rel.select(.{.id}).plugin_context.clock.?.fixed);
    try testing.expectEqual(t0, rel.allowFallback().plugin_context.clock.?.fixed);
}

// -- writing a plugin ------------------------------------------------------

var log: [8][]const u8 = undefined;
var log_len: usize = 0;

fn Logger(comptime tag: []const u8) type {
    return struct {
        pub fn beforeCreate(comptime S: type, tuple: *S.Tuple, _: *const zom.plugins.Context) void {
            log[log_len] = tag;
            log_len += 1;
            tuple.title = tag;
        }
    };
}

const Strict = struct {
    pub fn beforeUpdate(comptime S: type, changes: *zom.plugins.ChangeList(S.Tuple), _: *const zom.plugins.Context) error{Frozen}!void {
        if (changes.find(.id) != null) return error.Frozen;
    }
};

test "custom plugins run in order, and their errors reach commit" {
    const LoggedSchema = zom.Schema(Note, "logged", .id, .{
        .plugins = .{ Logger("first"), Logger("second"), Strict },
    });
    const Logged = zom.Relation(LoggedSchema, zom.memory.Gateway);

    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const rel = try Logged.init(&gw);

    log_len = 0;
    const stored = try rel.create(.{ .id = 1, .title = "x" }).commit();
    try testing.expectEqual(@as(usize, 2), log_len);
    try testing.expectEqualStrings("first", log[0]);
    try testing.expectEqualStrings("second", log[1]);
    try testing.expectEqualStrings("second", stored.title);

    try testing.expectError(error.Frozen, rel.byPk(1).update().set(.id, 2).commit());
    try testing.expectEqual(@as(usize, 1), try rel.byPk(1).update().set(.title, "y").commit());
}

test "a container sets the plugin context, and transactions keep it" {
    const App = zom.Container(.{
        .gateways = .{ .default = zom.memory.Gateway },
        .relations = .{ .notes = .{ NoteSchema, .default }, .users = .{ fixtures.Users.schema, .default } },
    });
    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();
    app.setPluginContext(.{ .clock = .{ .fixed = t1 } });

    try app.transaction(.default, {}, struct {
        fn f(_: void, tx: App.Relations) !void {
            _ = try tx.notes.create(.{ .id = 1, .title = "a" }).commit();
        }
    }.f);
    try testing.expectEqual(t1, (try app.relations.notes.byPk(1).one(testing.allocator)).?.created_at);
}

// -- no plugins, no cost ---------------------------------------------------

test "a schema without plugins adds nothing to its relation or changesets" {
    const Users = fixtures.Users;
    try testing.expectEqual(0, Users.schema.plugins.len);
    try testing.expect(Users.PluginContext == void);

    // The relation is exactly its fields from before plugins existed.
    const Before = struct { dataset: *Users.DatasetT, query: Users.Q = .{}, on_scan: ?zom.ScanHook = null };
    try testing.expectEqual(@sizeOf(Before), @sizeOf(Users));
    try testing.expectEqual(@sizeOf(struct { r: Before, t: Users.Tuple }), @sizeOf(zom.changeset.Create(Users)));

    // And `commit` on a batch needs no allocator.
    var gw = zom.memory.Gateway.init(testing.allocator, .{});
    defer gw.deinit();
    const users = try Users.init(&gw);
    const rows = [_]fixtures.UserTuple{.{ .id = 1, .name = "a", .email = "a@x", .age = 1 }};
    try testing.expectEqual(@as(usize, 1), try users.createMany(&rows).commit());
}
