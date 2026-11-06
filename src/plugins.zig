//! Plugins: comptime mixins configured on a schema.
//!
//!     const PostSchema = zom.Schema(Post, "posts", .id, .{
//!         .plugins = .{zom.plugins.timestamps(.{ .created = .created_at, .updated = .updated_at })},
//!     });
//!
//! A plugin is a type with any of these optional declarations. zom looks
//! each one up with `@hasDecl` and calls the ones present, plugin by plugin
//! in the order of `.plugins`:
//!
//!     /// At schema analysis: check the tuple, with @compileError on misuse.
//!     pub fn validate(comptime S: type) void
//!
//!     /// In `Create.commit` / `CreateMany.commitAlloc`, on the tuple about
//!     /// to be inserted (a copy: the caller's value is not changed).
//!     pub fn beforeCreate(comptime S: type, tuple: *S.Tuple, ctx: *const zom.plugins.Context) void
//!
//!     /// In `Update.commit`, on the changes about to be applied. Not called
//!     /// for an update with no changes, which stays a no-op.
//!     pub fn beforeUpdate(comptime S: type, changes: *zom.plugins.ChangeList(S.Tuple), ctx: *const zom.plugins.Context) void
//!
//! A hook may also return an error union (`!void`); its errors are added to
//! the commit's. `S` is the schema, so one plugin type works for any tuple.
//! A type in `.plugins` that declares none of the three is a compile error,
//! which catches a misspelt hook name.
//!
//! ## The context and the clock
//!
//! Hooks read runtime state, such as the time, from a `Context` held by the
//! relation: set it with `relation.withPluginContext(.{ .clock = ... })`, or
//! once for every relation with `app.setPluginContext(...)` on a container.
//! Plugins never read the system clock themselves, so tests pass a
//! `.{ .fixed = ns }` clock and get the same rows every run.
//!
//! ## No plugins, no cost
//!
//! A schema without `.plugins` has `S.plugins = .{}`. The relation's
//! `plugin_context` field is then `void`, and every dispatch is an
//! `inline for` over an empty tuple behind a comptime-false check, so the
//! relation and its changesets are the same size and commit the same way as
//! before plugins existed (tested in plugins_test.zig).

const std = @import("std");
const q = @import("query.zig");

const EnumLiteral = @TypeOf(.enum_literal);

/// The most changes one update holds, including the ones plugins add.
pub const max_changes = 16;

/// Where `now()` comes from. Times are nanoseconds since the Unix epoch, UTC.
pub const Clock = union(enum) {
    /// The real-time clock of an `std.Io`.
    io: std.Io,
    /// Always this time: for tests.
    fixed: i64,
    /// Anything else, e.g. a test clock that advances on each call.
    func: Func,

    pub const Func = struct {
        ctx: ?*anyopaque = null,
        now: *const fn (ctx: ?*anyopaque) i64,
    };

    /// Nanoseconds since the Unix epoch. An `.io` clock past the year 2262
    /// overflows `i64`, which is a panic in safe builds.
    pub fn now(c: Clock) i64 {
        return switch (c) {
            .io => |io| @intCast(std.Io.Clock.real.now(io).toNanoseconds()),
            .fixed => |ns| ns,
            .func => |f| f.now(f.ctx),
        };
    }
};

/// The runtime state plugin hooks get. Only relations whose schema has
/// plugins hold one.
pub const Context = struct {
    /// Needed by plugins that read the time, such as `timestamps`.
    clock: ?Clock = null,
};

/// The changes of an update, as `beforeUpdate` hooks see them. Holds at most
/// `max_changes`, the same limit as `Update.set`.
pub fn ChangeList(comptime T: type) type {
    return struct {
        const Self = @This();
        const Q = q.Query(T);
        pub const Change = Q.Change;
        pub const Field = Q.Field;
        pub const capacity = max_changes;

        items: [capacity]Change = undefined,
        len: usize = 0,

        pub fn slice(self: *const Self) []const Change {
            return self.items[0..self.len];
        }

        /// The index of the first change to `field`, if any.
        pub fn find(self: *const Self, field: Field) ?usize {
            for (self.slice(), 0..) |c, i| {
                if (c.field == field) return i;
            }
            return null;
        }

        /// `Update.set` for a hook: the same compile-time type checks, and
        /// `error.TooManyChanges` instead of an assertion when full.
        pub fn append(self: *Self, comptime field: Field, value: anytype) error{TooManyChanges}!void {
            const F = @FieldType(T, @tagName(field));
            comptime q.assertSettable(F, @TypeOf(value), @tagName(field));
            if (comptime q.isComptimeOnly(@TypeOf(value))) comptime q.assertLiteral(F, value, @tagName(field));
            if (self.len == capacity) return error.TooManyChanges;
            self.items[self.len] = .{ .field = field, .value = q.toValue(value) };
            self.len += 1;
        }
    };
}

const hook_names = [_][]const u8{ "validate", "beforeCreate", "beforeUpdate" };

/// Checks the `.plugins` option of schema `schema_name` and returns it.
pub fn checkList(comptime schema_name: []const u8, comptime list: anytype) @TypeOf(list) {
    const where = "zom.Schema(\"" ++ schema_name ++ "\"): ";
    const L = @TypeOf(list);
    const info = @typeInfo(L);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError(where ++ "`.plugins` must be a tuple of plugin types such as `.{zom.plugins.timestamps(.{})}`, found `" ++
            @typeName(L) ++ "`");
    for (info.@"struct".fields, 0..) |f, i| {
        if (f.type != type)
            @compileError(std.fmt.comptimePrint("{s}plugin {d} must be a type, found a value of type `{s}`", .{ where, i, @typeName(f.type) }));
        const P = list[i];
        const ok = switch (@typeInfo(P)) {
            .@"struct", .@"union", .@"enum", .@"opaque" => blk: {
                for (hook_names) |h| {
                    if (@hasDecl(P, h)) break :blk true;
                }
                break :blk false;
            },
            else => false,
        };
        if (!ok)
            @compileError(where ++ "plugin `" ++ @typeName(P) ++ "` declares none of the plugin hooks (validate, beforeCreate, beforeUpdate)");
    }
    return list;
}

/// Whether any plugin of schema `S` declares `hook`.
pub fn hasHook(comptime S: type, comptime hook: []const u8) bool {
    inline for (S.plugins) |P| {
        if (@hasDecl(P, hook)) return true;
    }
    return false;
}

/// The type of a relation's `plugin_context` field: `void` without plugins.
pub fn ContextField(comptime S: type) type {
    return if (S.plugins.len == 0) void else Context;
}

/// Calls every plugin's `validate`.
pub fn validate(comptime S: type) void {
    inline for (S.plugins) |P| {
        if (@hasDecl(P, "validate")) P.validate(S);
    }
}

/// Calls every plugin's `beforeCreate` on `tuple`.
pub inline fn beforeCreate(comptime S: type, tuple: *S.Tuple, ctx: *const ContextField(S)) !void {
    inline for (S.plugins) |P| {
        if (comptime @hasDecl(P, "beforeCreate")) {
            const r = P.beforeCreate(S, tuple, ctx);
            if (comptime @typeInfo(@TypeOf(r)) == .error_union) try r;
        }
    }
}

/// Calls every plugin's `beforeUpdate` on `changes`.
pub inline fn beforeUpdate(comptime S: type, changes: *ChangeList(S.Tuple), ctx: *const ContextField(S)) !void {
    inline for (S.plugins) |P| {
        if (comptime @hasDecl(P, "beforeUpdate")) {
            const r = P.beforeUpdate(S, changes, ctx);
            if (comptime @typeInfo(@TypeOf(r)) == .error_union) try r;
        }
    }
}

// -- timestamps ---------------------------------------------------------

/// What an integer timestamp field counts.
pub const Unit = enum {
    seconds,
    milliseconds,
    microseconds,
    nanoseconds,

    fn fromNanoseconds(u: Unit, ns: i64) i64 {
        return switch (u) {
            .seconds => @divFloor(ns, std.time.ns_per_s),
            .milliseconds => @divFloor(ns, std.time.ns_per_ms),
            .microseconds => @divFloor(ns, std.time.ns_per_us),
            .nanoseconds => ns,
        };
    }
};

pub const TimestampOptions = struct {
    /// Set on create. Null for none.
    created: ?EnumLiteral = .created_at,
    /// Set on create, and on every update that changes something. Null for none.
    updated: ?EnumLiteral = .updated_at,
    /// What the `i64` fields count from the Unix epoch.
    unit: Unit = .nanoseconds,
};

/// rom's timestamps plugin: `created_at` and `updated_at` (or the fields
/// named in `opts`, both `i64`) are set from the context's clock. Create
/// sets both, overwriting what the tuple held. An update that changes
/// anything also sets `updated`, unless it already sets it itself; that
/// change counts towards `max_changes`, so an update with all 16 changes
/// fails with `error.TooManyChanges`.
pub fn timestamps(comptime opts: TimestampOptions) type {
    const created: ?[]const u8 = if (opts.created) |f| @tagName(f) else null;
    const updated: ?[]const u8 = if (opts.updated) |f| @tagName(f) else null;
    if (created == null and updated == null)
        @compileError("zom.plugins.timestamps: `.created` and `.updated` are both null, so there is nothing to set");
    if (created != null and updated != null and std.mem.eql(u8, created.?, updated.?))
        @compileError("zom.plugins.timestamps: `.created` and `.updated` are both '" ++ created.? ++ "'");

    return struct {
        pub fn validate(comptime S: type) void {
            if (created) |name| checkField(S, name, ".created");
            if (updated) |name| checkField(S, name, ".updated");
        }

        pub fn beforeCreate(comptime S: type, tuple: *S.Tuple, ctx: *const Context) void {
            const t = now(S, ctx);
            if (created) |name| @field(tuple, name) = t;
            if (updated) |name| @field(tuple, name) = t;
        }

        pub fn beforeUpdate(comptime S: type, changes: *ChangeList(S.Tuple), ctx: *const Context) error{TooManyChanges}!void {
            const name = updated orelse return;
            const field = @field(ChangeList(S.Tuple).Field, name);
            if (changes.find(field) != null) return;
            try changes.append(field, now(S, ctx));
        }

        fn now(comptime S: type, ctx: *const Context) i64 {
            const clock = ctx.clock orelse std.debug.panic(
                "zom.plugins.timestamps: relation '{s}' has no clock; set one with " ++
                    "`relation.withPluginContext(.{{ .clock = ... }})` or `app.setPluginContext(...)`",
                .{S.name},
            );
            return opts.unit.fromNanoseconds(clock.now());
        }

        fn checkField(comptime S: type, comptime name: []const u8, comptime option: []const u8) void {
            const where = "zom.plugins.timestamps on schema \"" ++ S.name ++ "\": ";
            if (!@hasField(S.Tuple, name))
                @compileError(where ++ "`" ++ option ++ "` field '" ++ name ++ "' is not a field of " ++
                    @typeName(S.Tuple) ++ " (pass `" ++ option ++ " = .other_field`, or null for none)");
            const F = @FieldType(S.Tuple, name);
            if (F != i64)
                @compileError(where ++ "field '" ++ name ++ "' is `" ++ @typeName(F) ++ "`, expected `i64`");
        }
    };
}
