const std = @import("std");
const zom = @import("../root.zig");
const testing = std.testing;
const fixtures = @import("fixtures.zig");

const UserSchema = fixtures.Users.schema;
const PostSchema = fixtures.Posts.schema;

test "two memory gateways and two relations, end to end" {
    const App = zom.Container(.{
        .gateways = .{ .default = zom.memory.Gateway, .archive = zom.memory.Gateway },
        .relations = .{ .users = .{ UserSchema, .default }, .posts = .{ PostSchema, .archive } },
    });

    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();

    const users = app.relations.users;
    const posts = app.relations.posts;
    try testing.expect(@TypeOf(users) == zom.Relation(UserSchema, zom.memory.Gateway));
    try fixtures.seed(users, posts);

    try testing.expectEqual(@as(usize, 3), try users.count());
    try testing.expectEqual(@as(usize, 2), try posts.where(.user_id, .eq, 1).count());

    // Each relation's dataset lives in the gateway it named.
    try testing.expectEqual(try app.gateways.default.dataset(UserSchema), users.dataset);
    try testing.expectEqual(try app.gateways.archive.dataset(PostSchema), posts.dataset);
    try testing.expectEqual(@as(usize, 1), app.gateways.default.datasets.count());
    try testing.expectEqual(@as(usize, 1), app.gateways.archive.datasets.count());

    const authors = try users.where(.id, .eq, 1).mapWith(fixtures.AuthorMapper, testing.allocator);
    defer testing.allocator.free(authors);
    try testing.expectEqualStrings("Achieng", authors[0].full_name);
}

test "Config fields default only when the gateway's Config is all defaults" {
    const App = zom.Container(.{
        .gateways = .{ .mem = zom.memory.Gateway, .needs = Fake("needs", .{}), .opt = Fake("opt", .{}) },
        .relations = .{},
    });
    const info = @typeInfo(App.Config).@"struct";
    try testing.expect(info.field_types[0] == zom.memory.Gateway.Config);
    try testing.expect(info.field_attrs[0].default_value_ptr != null);
    // Fake's Config has a field without a default.
    try testing.expect(info.field_attrs[1].default_value_ptr == null);

    const Defaults = zom.Container(.{
        .gateways = .{ .a = Defaulted, .b = zom.memory.Gateway },
        .relations = .{},
    });
    const config: Defaults.Config = .{};
    try testing.expectEqual(@as(u32, 7), config.a.port);
}

test "a gateway that fails to init deinitialises the ones before it" {
    log.reset();
    const App = zom.Container(.{
        .gateways = .{ .first = Fake("first", .{}), .second = Fake("second", .{ .fail_init = true }), .third = Fake("third", .{}) },
        .relations = .{ .items = .{ ItemSchema, .first } },
    });
    var app: App = undefined;
    try testing.expectError(error.ConnectFailed, app.init(testing.allocator, .{
        .first = .{ .id = 1 },
        .second = .{ .id = 2 },
        .third = .{ .id = 3 },
    }));
    try testing.expectEqualStrings("init first;init second;deinit first;", log.text());
}

test "a relation that fails to build deinitialises every gateway, last first" {
    log.reset();
    const App = zom.Container(.{
        .gateways = .{ .first = Fake("first", .{}), .second = Fake("second", .{ .fail_dataset = true }) },
        .relations = .{ .a = .{ ItemSchema, .first }, .b = .{ ItemSchema, .second } },
    });
    var app: App = undefined;
    try testing.expectError(error.NoSuchDataset, app.init(testing.allocator, .{
        .first = .{ .id = 1 },
        .second = .{ .id = 2 },
    }));
    try testing.expectEqualStrings(
        "init first;init second;dataset first;dataset second;deinit second;deinit first;",
        log.text(),
    );
}

test "deinit runs in reverse declaration order" {
    log.reset();
    const App = zom.Container(.{
        .gateways = .{ .first = Fake("first", .{}), .second = Fake("second", .{}) },
        .relations = .{},
    });
    var app: App = undefined;
    try app.init(testing.allocator, .{ .first = .{ .id = 1 }, .second = .{ .id = 2 } });
    try testing.expectEqual(@as(u32, 2), app.gateways.second.id);
    app.deinit();
    try testing.expectEqualStrings("init first;init second;deinit second;deinit first;", log.text());
}

test "a gateway that keeps its dataset inline works, because init fills in place" {
    const App = zom.Container(.{
        .gateways = .{ .default = InlineGateway },
        .relations = .{ .items = .{ ItemSchema, .default } },
    });
    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();

    try testing.expectEqual(&app.gateways.default.items, app.relations.items.dataset);
    _ = try app.relations.items.create(.{ .id = 1, .name = "one" }).commit();
    try testing.expectEqual(@as(usize, 1), app.gateways.default.items.rows().len);
}

// -- transactions -----------------------------------------------------------

const TxApp = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway, .archive = zom.memory.Gateway },
    .relations = .{ .users = .{ UserSchema, .default }, .posts = .{ PostSchema, .archive } },
});

fn addUser(users: fixtures.Users, id: u32, name: []const u8) !void {
    _ = try users.create(.{ .id = id, .name = name, .email = "x@example.com", .age = 30 }).commit();
}

test "transaction on memory: f's writes stay when it returns, and its result comes back" {
    var app: TxApp = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();

    const n = try app.transaction(.default, @as(u32, 2), struct {
        fn f(id: u32, tx: TxApp.Relations) !usize {
            try addUser(tx.users, 1, "Achieng");
            try addUser(tx.users, id, "Otieno");
            return tx.users.count();
        }
    }.f);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqual(@as(usize, 2), try app.relations.users.count());
}

test "transaction on memory: an error rolls back the gateway's stores and comes back unchanged" {
    var app: TxApp = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();
    try addUser(app.relations.users, 1, "Achieng");
    // A row read before the transaction must survive its rollback.
    const before = try app.relations.users.byPk(1).one(testing.allocator);

    const result = app.transaction(.default, {}, struct {
        fn f(_: void, tx: TxApp.Relations) !void {
            try addUser(tx.users, 2, "Otieno");
            _ = try tx.users.byPk(1).update().set(.name, "Renamed").commit();
            try addUser(tx.users, 2, "again");
        }
    }.f);
    try testing.expectError(error.DuplicatePrimaryKey, result);

    const rows = try app.relations.users.toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 1), rows.len);
    try testing.expectEqualStrings("Achieng", rows[0].name);
    try testing.expectEqualStrings("Achieng", before.?.name);
}

test "transaction on memory: relations on other gateways are not part of it" {
    var app: TxApp = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();

    const result = app.transaction(.default, {}, struct {
        fn f(_: void, tx: TxApp.Relations) !void {
            try addUser(tx.users, 1, "Achieng");
            _ = try tx.posts.create(.{ .id = 10, .user_id = 1, .title = "kept", .published = true }).commit();
            return error.Boom;
        }
    }.f);
    try testing.expectError(error.Boom, result);
    try testing.expectEqual(@as(usize, 0), try app.relations.users.count());
    try testing.expectEqual(@as(usize, 1), try app.relations.posts.count());
}

test "transaction on memory: f may return a plain value, and calls nest" {
    var app: TxApp = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();

    const v = try app.transaction(.default, @as(u32, 41), struct {
        fn f(x: u32, _: TxApp.Relations) u32 {
            return x + 1;
        }
    }.f);
    try testing.expectEqual(@as(u32, 42), v);

    try app.transaction(.default, &app, struct {
        fn f(a: *TxApp, tx: TxApp.Relations) !void {
            try addUser(tx.users, 1, "Achieng");
            // The inner one fails; only its rows go.
            const inner = a.transaction(.default, {}, struct {
                fn f(_: void, inner_tx: TxApp.Relations) !void {
                    try addUser(inner_tx.users, 2, "Otieno");
                    try addUser(inner_tx.users, 1, "dup");
                }
            }.f);
            try testing.expectError(error.DuplicatePrimaryKey, inner);
            try addUser(tx.users, 3, "Wanjiru");
        }
    }.f);
    const rows = try app.relations.users.order(.id, .asc).toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try testing.expectEqual(@as(usize, 2), rows.len);
    try testing.expectEqual(@as(u32, 1), rows[0].id);
    try testing.expectEqual(@as(u32, 3), rows[1].id);
}

test "transaction rebinds the gateway's relations to the gateway f is given, keeping on_scan" {
    const App = zom.Container(.{
        .gateways = .{ .default = Pinning, .other = zom.memory.Gateway },
        .relations = .{ .users = .{ UserSchema, .default }, .posts = .{ PostSchema, .other } },
        .on_scan = noteScan,
    });
    var app: App = undefined;
    try app.init(testing.allocator, .{});
    defer app.deinit();

    try app.transaction(.default, &app, struct {
        fn f(a: *App, tx: App.Relations) !void {
            const pinned = Pinning.current.?;
            try testing.expect(pinned != &a.gateways.default);
            try testing.expectEqual(try pinned.dataset(UserSchema), tx.users.dataset);
            try testing.expect(tx.users.dataset != a.relations.users.dataset);
            try testing.expectEqual(a.relations.posts.dataset, tx.posts.dataset);
            try testing.expectEqual(@as(?zom.ScanHook, &noteScan), tx.users.on_scan);
        }
    }.f);
    try testing.expectEqual(@as(?*Pinning, null), Pinning.current);
}

fn noteScan(_: zom.Scan) void {}

/// Like zom-pg: `transaction` hands `f` a different gateway of the same
/// type, with datasets of its own.
const Pinning = struct {
    pub const adapter_name = "pinning";
    pub const Config = struct {};

    var current: ?*Pinning = null;

    inner: zom.memory.Gateway,

    pub fn init(allocator: std.mem.Allocator, _: Config) Pinning {
        return .{ .inner = .init(allocator, .{}) };
    }
    pub fn deinit(self: *Pinning) void {
        self.inner.deinit();
    }
    pub fn Dataset(comptime S: type) type {
        return zom.memory.Store(S);
    }
    pub fn dataset(self: *Pinning, comptime S: type) !*Dataset(S) {
        return self.inner.dataset(S);
    }
    pub fn transaction(self: *Pinning, ctx: anytype, comptime f: anytype) @TypeOf(f(@as(@TypeOf(ctx), undefined), @as(*Pinning, undefined))) {
        var tx: Pinning = .init(self.inner.allocator, .{});
        defer tx.deinit();
        current = &tx;
        defer current = null;
        return f(ctx, &tx);
    }
};

// -- fakes ----------------------------------------------------------------

const Item = struct { id: u32, name: []const u8 = "" };
const ItemSchema = zom.Schema(Item, "items", .id, .{});

/// Records every gateway call, so tests can check what ran and in what order.
const log = struct {
    var buf: [256]u8 = undefined;
    var len: usize = 0;

    fn reset() void {
        len = 0;
    }
    fn add(comptime event: []const u8, name: []const u8) void {
        const line = std.fmt.bufPrint(buf[len..], event ++ " {s};", .{name}) catch unreachable;
        len += line.len;
    }
    fn text() []const u8 {
        return buf[0..len];
    }
};

const FakeOptions = struct { fail_init: bool = false, fail_dataset: bool = false };

/// A gateway that logs its calls and can fail `init` or `dataset`. Its
/// `Config` has a required field, so the container's `Config` has no
/// default for it.
fn Fake(comptime name: []const u8, comptime options: FakeOptions) type {
    return struct {
        const Self = @This();

        pub const adapter_name = "fake";
        pub const Config = struct { id: u32 };

        id: u32,

        pub fn init(_: std.mem.Allocator, config: Config) !Self {
            log.add("init", name);
            if (options.fail_init) return error.ConnectFailed;
            return .{ .id = config.id };
        }

        pub fn deinit(_: *Self) void {
            log.add("deinit", name);
        }

        pub fn Dataset(comptime S: type) type {
            return ReadOnly(S);
        }

        pub fn dataset(_: *Self, comptime S: type) !*Dataset(S) {
            log.add("dataset", name);
            if (options.fail_dataset) return error.NoSuchDataset;
            const static = struct {
                var instance: Dataset(S) = .{};
            };
            return &static.instance;
        }
    };
}

fn ReadOnly(comptime S: type) type {
    const Q = zom.Query(S.Tuple);
    return struct {
        pub fn read(_: *@This(), _: Q, a: std.mem.Allocator) ![]S.Tuple {
            return a.alloc(S.Tuple, 0);
        }
        pub fn count(_: *@This(), _: Q) !usize {
            return 0;
        }
    };
}

/// A gateway whose `Config` fields all have defaults.
const Defaulted = struct {
    pub const adapter_name = "defaulted";
    pub const Config = struct { port: u32 = 7, host: []const u8 = "localhost" };

    pub fn init(_: std.mem.Allocator, _: Config) Defaulted {
        return .{};
    }
    pub fn deinit(_: *Defaulted) void {}
    pub fn Dataset(comptime S: type) type {
        return ReadOnly(S);
    }
    pub fn dataset(_: *Defaulted, comptime S: type) !*Dataset(S) {
        return error.NoSuchDataset;
    }
};

/// A gateway that keeps its one dataset inside itself rather than on the
/// heap, so a relation's dataset pointer is only valid while the gateway
/// stays put.
const InlineGateway = struct {
    pub const adapter_name = "inline";
    pub const Config = struct {};

    items: zom.memory.Store(ItemSchema),

    pub fn init(allocator: std.mem.Allocator, _: Config) InlineGateway {
        return .{ .items = .init(allocator) };
    }
    pub fn deinit(self: *InlineGateway) void {
        self.items.deinit();
    }
    pub fn Dataset(comptime S: type) type {
        return zom.memory.Store(S);
    }
    pub fn dataset(self: *InlineGateway, comptime S: type) !*Dataset(S) {
        if (S != ItemSchema) return error.NoSuchDataset;
        return &self.items;
    }
};
