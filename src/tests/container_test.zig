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
    const fields = @typeInfo(App.Config).@"struct".fields;
    try testing.expect(fields[0].type == zom.memory.Gateway.Config);
    try testing.expect(fields[0].default_value_ptr != null);
    // Fake's Config has a field without a default.
    try testing.expect(fields[1].default_value_ptr == null);

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
