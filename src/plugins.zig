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
//!     /// Around every dataset call (see "Instrumentation" below).
//!     pub fn before(event: zom.plugins.instrumentation.Event) void
//!     pub fn after(event: zom.plugins.instrumentation.Event, outcome: zom.plugins.instrumentation.Outcome) void
//!
//! A `validate`, `beforeCreate` or `beforeUpdate` hook may also return an
//! error union (`!void`); its errors are added to the commit's. `S` is the schema, so one plugin type works for any tuple.
//! A type in `.plugins` that declares none of these hooks is a compile
//! error, which catches a misspelt hook name.
//!
//! ## The context and the clock
//!
//! Hooks read runtime state, such as the time, from a `Context` held by the
//! relation: set it with `relation.withPluginContext(.{ .clock = ... })`, or
//! once for every relation with `app.setPluginContext(...)` on a container.
//! Plugins never read the system clock themselves, so tests pass a
//! `.{ .fixed = ns }` clock and get the same rows every run.
//!
//! ## Instrumentation
//!
//! A plugin with `before` and/or `after` is called around each call the
//! relation and its changesets make to the dataset: `read` (and
//! `readProjected`), `count`, `insert`, `insertMany`, `update` and
//! `delete`, so one `users.create(...).commit()` is one `.insert` event.
//! `before` gets the `Event` (adapter, dataset, op, and the query handed to
//! the dataset), and `after` the same event and its `Outcome`: the rows the
//! dataset returned or changed, or the `@errorName` of its error, and the
//! duration. `after` runs on errors too.
//!
//!     const UserSchema = zom.Schema(User, "users", .id, .{
//!         .plugins = .{zom.plugins.instrumentation.log(std.log.scoped(.zom))},
//!     });
//!
//! `instrumentation.log` is the ready-made hook: it logs each call at
//! `.debug`, and each failed one at `.warn`. A `.fallback` read that runs
//! part of its query in memory is a `.read` whose `rows` is what the
//! dataset returned, so this also shows how many rows it scanned.
//!
//! The duration comes from the context's clock, like `timestamps`' time: it
//! is null without one, and an `.io` clock is read with the monotonic
//! `awake` clock. Hooks are plain functions, like a `ScanHook`, so a hook
//! that keeps counts keeps them in container-level `var`s. Hooks run in
//! the order of `.plugins`.
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

    /// Nanoseconds for measuring a duration: `now()`, except that an `.io`
    /// clock reads the monotonic `awake` clock, which no time change moves.
    pub fn ticks(c: Clock) i64 {
        return switch (c) {
            .io => |io| @intCast(std.Io.Clock.awake.now(io).toNanoseconds()),
            else => c.now(),
        };
    }

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

const hook_names = [_][]const u8{ "validate", "beforeCreate", "beforeUpdate", "before", "after" };

/// Checks the `.plugins` option of schema `schema_name` and returns it.
pub fn checkList(comptime schema_name: []const u8, comptime list: anytype) @TypeOf(list) {
    const where = "zom.Schema(\"" ++ schema_name ++ "\"): ";
    const L = @TypeOf(list);
    const info = @typeInfo(L);
    if (info != .@"struct" or !info.@"struct".is_tuple)
        @compileError(where ++ "`.plugins` must be a tuple of plugin types such as `.{zom.plugins.timestamps(.{})}`, found `" ++
            @typeName(L) ++ "`");
    for (info.@"struct".field_types, 0..) |F, i| {
        if (F != type)
            @compileError(std.fmt.comptimePrint("{s}plugin {d} must be a type, found a value of type `{s}`", .{ where, i, @typeName(F) }));
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
            @compileError(where ++ "plugin `" ++ @typeName(P) ++ "` declares none of the plugin hooks (validate, beforeCreate, beforeUpdate, before, after)");
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

// -- instrumentation ----------------------------------------------------

/// The types instrumentation hooks take, and the ready-made `log` hook.
/// See "Instrumentation" at the top of this file.
pub const instrumentation = struct {
    /// The dataset call.
    pub const Op = enum { read, count, insert, insert_many, update, delete };

    /// One dataset call, as `before` and `after` see it.
    pub const Event = struct {
        /// The adapter's name, e.g. "memory".
        adapter: []const u8,
        /// The schema's dataset name, e.g. "users".
        dataset: []const u8,
        op: Op,
        /// The `zom.Query(Tuple)` handed to the dataset, for every op but
        /// the inserts, which have none. Read it with `queryOf`. Valid
        /// only during the hook.
        query: ?*const anyopaque,
        /// `@typeName` of the tuple, which `queryOf` checks.
        tuple: []const u8,

        /// The query as a `zom.Query(T)`, where `T` must be the schema's
        /// tuple (checked against `tuple` in safe builds).
        pub fn queryOf(e: Event, comptime T: type) ?*const q.Query(T) {
            const ptr = e.query orelse return null;
            std.debug.assert(std.mem.eql(u8, e.tuple, @typeName(T)));
            return @ptrCast(@alignCast(ptr));
        }
    };

    /// How a dataset call went, as `after` sees it.
    pub const Outcome = struct {
        /// Measured with the context's clock (`Clock.ticks`); null when the
        /// relation has none.
        duration_ns: ?u64,
        /// The rows read, counted, inserted, updated or deleted: the slice
        /// length, the count, 1 for an insert. Null on an error.
        rows: ?usize,
        /// `@errorName` of the dataset's error, or null when it succeeded.
        err: ?[]const u8,
    };

    /// A plugin that logs each dataset call to `Logger`, a
    /// `std.log.scoped(...)`: successes at `.debug`, errors at `.warn`.
    /// The application sets the level with `std_options.log_level` or
    /// `log_scope_levels`.
    pub fn log(comptime Logger: type) type {
        return struct {
            pub fn after(e: Event, o: Outcome) void {
                if (o.err) |name| {
                    Logger.warn("{s} {s} on '{s}' failed: {s}", .{ e.adapter, @tagName(e.op), e.dataset, name });
                } else if (o.duration_ns) |ns| {
                    Logger.debug("{s} {s} on '{s}': {d} rows in {d}ns", .{ e.adapter, @tagName(e.op), e.dataset, o.rows.?, ns });
                } else {
                    Logger.debug("{s} {s} on '{s}': {d} rows", .{ e.adapter, @tagName(e.op), e.dataset, o.rows.? });
                }
            }
        };
    }
};

/// Whether schema `S` has an instrumentation plugin.
pub fn instrumented(comptime S: type) bool {
    return hasHook(S, "before") or hasHook(S, "after");
}

/// One dataset call in progress: `begin` calls the `before` hooks, and
/// `end(result)` the `after` hooks with the call's result, which it
/// returns. Without instrumentation it is an empty struct whose `end`
/// returns `result`, so nothing is measured or called.
pub fn Span(comptime S: type) type {
    if (!instrumented(S)) return struct {
        pub inline fn end(_: @This(), result: anytype) @TypeOf(result) {
            return result;
        }
    };
    return struct {
        const Self = @This();

        event: instrumentation.Event,
        clock: ?Clock,
        start: i64,

        pub inline fn end(self: Self, result: anytype) @TypeOf(result) {
            const stop: ?i64 = if (self.clock) |c| c.ticks() else null;
            const R = @TypeOf(result);
            var outcome: instrumentation.Outcome = .{
                .duration_ns = if (stop) |t| @intCast(@max(0, t - self.start)) else null,
                .rows = null,
                .err = null,
            };
            if (comptime @typeInfo(R) == .error_union) {
                if (result) |v| {
                    outcome.rows = rowsOf(v);
                } else |e| {
                    outcome.err = @errorName(e);
                }
            } else {
                outcome.rows = rowsOf(result);
            }
            inline for (S.plugins) |P| {
                if (comptime @hasDecl(P, "after")) P.after(self.event, outcome);
            }
            return result;
        }
    };
}

/// Starts a span for `op` on schema `S`'s dataset, calling the `before`
/// hooks. `query` is what the dataset gets, or null for an insert.
pub inline fn begin(
    comptime S: type,
    comptime adapter_name: []const u8,
    comptime op: instrumentation.Op,
    query: ?*const q.Query(S.Tuple),
    ctx: *const ContextField(S),
) Span(S) {
    if (comptime !instrumented(S)) return .{};
    const event: instrumentation.Event = .{
        .adapter = adapter_name,
        .dataset = S.name,
        .op = op,
        .query = query,
        .tuple = @typeName(S.Tuple),
    };
    inline for (S.plugins) |P| {
        if (comptime @hasDecl(P, "before")) P.before(event);
    }
    // Read after the `before` hooks, so their time is not counted.
    return .{ .event = event, .clock = ctx.clock, .start = if (ctx.clock) |c| c.ticks() else 0 };
}

/// The rows a dataset call's result stands for.
fn rowsOf(value: anytype) usize {
    const T = @TypeOf(value);
    if (T == usize) return value;
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice) return value.len;
    return 1; // An inserted tuple.
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
