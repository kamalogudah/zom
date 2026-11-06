//! `combine` through a dataset's own `loadAssociation` (combine.zig): a
//! custom association, and a `hasMany` the dataset takes over.

const std = @import("std");
const testing = std.testing;
const zom = @import("../root.zig");

const Person = struct { id: u32, name: []const u8 };
const Message = struct { id: u32, sender_id: u32, recipient_id: u32, body: []const u8 };

const PersonSchema = zom.Schema(Person, "people", .id, .{
    .associations = struct {
        /// Every message a person sent or received: no single foreign key.
        pub const conversation = zom.customAssociation(MessageSchema, .both_sides, .many);
        /// The first message they sent, in the combined relation's order.
        pub const first_sent = zom.customAssociation(MessageSchema, .sender, .one);
        pub const sent = zom.hasMany(MessageSchema, .sender_id);
    },
});
const MessageSchema = zom.Schema(Message, "messages", .id, .{});

/// The memory gateway, but the messages dataset loads associations itself
/// and counts its calls; the people dataset is memory's own.
const HookGateway = struct {
    pub const adapter_name = "hooked";
    pub const Config = struct {};

    inner: zom.memory.Gateway,
    messages: MessageStore = .{},

    pub fn init(allocator: std.mem.Allocator, _: Config) HookGateway {
        return .{ .inner = .init(allocator, .{}) };
    }

    pub fn deinit(self: *HookGateway) void {
        self.inner.deinit();
    }

    pub fn Dataset(comptime S: type) type {
        return if (S == MessageSchema) MessageStore else zom.memory.Store(S);
    }

    pub fn dataset(self: *HookGateway, comptime S: type) !*Dataset(S) {
        if (S != MessageSchema) return self.inner.dataset(S);
        self.messages.store = try self.inner.dataset(S);
        return &self.messages;
    }

    const MessageStore = struct {
        const T = Message;
        const Q = zom.Query(T);
        pub const supports: zom.Supports = blk: {
            var all: zom.Supports = .all;
            all.projection = false;
            break :blk all;
        };

        store: *zom.memory.Store(MessageSchema) = undefined,
        loads: usize = 0,
        reads: usize = 0,

        pub fn read(self: *MessageStore, query: Q, allocator: std.mem.Allocator) ![]T {
            self.reads += 1;
            return self.store.read(query, allocator);
        }
        pub fn count(self: *MessageStore, query: Q) !usize {
            return self.store.count(query);
        }
        pub fn insert(self: *MessageStore, row: T) !T {
            return self.store.insert(row);
        }

        /// One read of everything `query` matches, then each key's rows
        /// picked out, in the query's order.
        pub fn loadAssociation(
            self: *MessageStore,
            comptime a: zom.Association,
            keys: []const a.Key(),
            query: Q,
            allocator: std.mem.Allocator,
        ) ![]const []const T {
            self.loads += 1;
            const rows = try self.store.read(query, allocator);
            const groups = try allocator.alloc([]const T, keys.len);
            for (keys, groups) |key, *g| {
                var list: std.ArrayList(T) = .empty;
                for (rows) |row| if (belongs(a, row, key)) try list.append(allocator, row);
                g.* = try list.toOwnedSlice(allocator);
            }
            return groups;
        }

        fn belongs(comptime a: zom.Association, row: T, key: u32) bool {
            if (a.kind == .has_many) return @field(row, a.foreign_key) == key;
            if (comptime std.mem.eql(u8, a.tag, "both_sides")) return row.sender_id == key or row.recipient_id == key;
            if (comptime std.mem.eql(u8, a.tag, "sender")) return row.sender_id == key;
            @compileError("unknown association " ++ a.name);
        }
    };
};

const People = zom.Relation(PersonSchema, HookGateway);
const Messages = zom.Relation(MessageSchema, HookGateway);

const Fixture = struct {
    gw: HookGateway,
    people: People,
    messages: Messages,

    fn init(self: *Fixture) !void {
        self.gw = .init(testing.allocator, .{});
        errdefer self.gw.deinit();
        self.people = try .init(&self.gw);
        self.messages = try .init(&self.gw);
        _ = try self.people.create(.{ .id = 1, .name = "Achieng" }).commit();
        _ = try self.people.create(.{ .id = 2, .name = "Otieno" }).commit();
        _ = try self.people.create(.{ .id = 3, .name = "Wanjiru" }).commit();
        _ = try self.messages.create(.{ .id = 10, .sender_id = 1, .recipient_id = 2, .body = "habari" }).commit();
        _ = try self.messages.create(.{ .id = 11, .sender_id = 2, .recipient_id = 1, .body = "nzuri" }).commit();
        _ = try self.messages.create(.{ .id = 12, .sender_id = 1, .recipient_id = 9, .body = "hello?" }).commit();
        self.gw.messages.loads = 0;
        self.gw.messages.reads = 0;
    }

    fn deinit(self: *Fixture) void {
        self.gw.deinit();
    }
};

fn ids(rows: anytype) [8]u32 {
    var out: [8]u32 = @splat(0);
    for (rows, 0..) |row, i| out[i] = row.id;
    return out;
}

fn expectIds(want: []const u32, rows: anytype) !void {
    try testing.expectEqual(want.len, rows.len);
    try testing.expectEqualSlices(u32, want, ids(rows)[0..rows.len]);
}

test "a custom association is loaded by the dataset: one call, a row in several groups" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const Talker = struct { id: u32, name: []const u8, conversation: []const Message };
    var result = try f.people.order(.id, .asc)
        .combine(.conversation, f.messages.order(.id, .desc))
        .mapTo(Talker, testing.allocator);
    defer result.deinit();

    // The generic `in` query never ran.
    try testing.expectEqual(1, f.gw.messages.loads);
    try testing.expectEqual(0, f.gw.messages.reads);
    const people = result.items;
    try testing.expectEqual(3, people.len);
    // 10 and 11 are between 1 and 2, so both have them, in the target's order.
    try expectIds(&.{ 12, 11, 10 }, people[0].conversation);
    try expectIds(&.{ 11, 10 }, people[1].conversation);
    try expectIds(&.{}, people[2].conversation);
}

test "the dataset gets the target relation's query, and the element type is mapped" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const Line = struct { id: u32, body: []const u8 };
    const Talker = struct { name: []const u8, conversation: []const Line };
    var result = try f.people.where(.id, .eq, 1)
        .combine(.conversation, f.messages.where(.body, .neq, "nzuri").order(.id, .asc))
        .mapTo(Talker, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(1, result.items.len);
    try expectIds(&.{ 10, 12 }, result.items[0].conversation);
    try testing.expectEqualStrings("hello?", result.items[0].conversation[1].body);

    // A `select` on the target narrows nothing the dataset sees: it gets
    // whole tuples, and zom maps them to the element.
    var narrow = try f.people.where(.id, .eq, 2)
        .combine(.conversation, f.messages.select(.{ .id, .body }))
        .mapTo(Talker, testing.allocator);
    defer narrow.deinit();
    try expectIds(&.{ 10, 11 }, narrow.items[0].conversation);
}

test "a custom .one association is an optional: the first row, or null" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const Sender = struct { id: u32, first_sent: ?Message };
    var result = try f.people.order(.id, .asc)
        .combine(.first_sent, f.messages.order(.id, .desc))
        .mapTo(Sender, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(12, result.items[0].first_sent.?.id);
    try testing.expectEqual(11, result.items[1].first_sent.?.id);
    try testing.expectEqual(null, result.items[2].first_sent);
}

test "a hasMany into a dataset with loadAssociation goes through it too" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();

    const Author = struct { id: u32, sent: []const Message };
    var result = try f.people.order(.id, .asc).combine(.sent, f.messages).mapTo(Author, testing.allocator);
    defer result.deinit();
    try testing.expectEqual(1, f.gw.messages.loads);
    try testing.expectEqual(0, f.gw.messages.reads);
    try expectIds(&.{ 10, 12 }, result.items[0].sent);
    try expectIds(&.{11}, result.items[1].sent);
    try expectIds(&.{}, result.items[2].sent);

    // And a paged target is still refused before anything is read.
    try testing.expectError(error.PagedCombineTarget, f.people.combine(.sent, f.messages.limit(1)).mapTo(Author, testing.allocator));
    try testing.expectEqual(1, f.gw.messages.loads);
}

test "custom associations: the descriptor" {
    const a = PersonSchema.association(.conversation);
    try testing.expectEqual(.custom, a.kind);
    try testing.expectEqual(.many, a.cardinality);
    try testing.expectEqualStrings("both_sides", a.tag);
    try testing.expectEqualStrings("id", a.primary_key);
    try testing.expectEqualStrings("", a.foreign_key);
    try testing.expect(a.Parent() == PersonSchema);
    try testing.expect(a.Key() == u32);
    try testing.expectEqual(.one, PersonSchema.association(.first_sent).cardinality);
    try testing.expectEqual(.many, PersonSchema.association(.sent).cardinality);
}
