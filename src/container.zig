//! Container = ROM's `ROM.container`.
//!
//! It declares the gateways and the relations over them once, as a comptime
//! type, and initialises and deinitialises every connection in one place:
//!
//!   const App = zom.Container(.{
//!       .gateways = .{ .default = zom.memory.Gateway, .files = zom_csv.Gateway },
//!       .relations = .{ .users = .{ UserSchema, .default }, .imports = .{ ImportSchema, .files } },
//!   });
//!
//!   var app: App = undefined;
//!   try app.init(allocator, .{ .files = .{ .io = io, .path = "data/" } });
//!   defer app.deinit();
//!   const users = app.relations.users;
//!
//! Relations are types, so `app.relations.users` is a struct field: a
//! misspelt relation, or one that names a gateway the container lacks, is a
//! compile error rather than a runtime lookup failure. Every gateway is
//! checked with `zom.Adapter`.
//!
//! An optional `.on_scan = hook` (a `fn (zom.Scan) void`) is set on every
//! relation, so each `.fallback` read that runs part of its query in memory
//! is reported in one place: tests can assert on it, and apps can log it.
//! Relations chained from `app.relations.users`, including through
//! `allowFallback()`, keep the hook.
//!
//! Plugins: `app.setPluginContext(.{ .clock = .{ .io = io } })` after
//! `init` gives the relations whose schemas have plugins what their hooks
//! read (see plugins.zig). Transactions keep it.
//!
//! Transactions: `app.transaction(.default, ctx, f)` runs `f(ctx, tx)` in
//! the `default` gateway's `transaction`, where `tx` is an `App.Relations`
//! whose relations on `default` run in the transaction:
//!
//!   try app.transaction(.default, {}, struct {
//!       fn f(_: void, tx: App.Relations) !void {
//!           _ = try tx.users.create(.{ ... }).commit();
//!           _ = try tx.posts.create(.{ ... }).commit();
//!       }
//!   }.f);
//!
//! Pointer stability: a relation holds a `*Dataset`, and the adapter contract
//! does not say where a dataset lives. The memory gateway heap-allocates its
//! datasets, but another gateway may keep one inside its own struct, and
//! then copying the gateway would leave the relation pointing at the old
//! copy. So `init` fills the container in place (`self: *Self`) instead of
//! returning it by value, and a container must not be copied or moved
//! between `init` and `deinit`.

const std = @import("std");
const adapter = @import("adapter.zig");
const rel = @import("relation.zig");
const plugins = @import("plugins.zig");
const Relation = rel.Relation;
const Allocator = std.mem.Allocator;

/// `spec` is an anonymous struct literal with two fields, and an optional
/// third:
///
///   .gateways  = .{ .name = GatewayType, ... }
///   .relations = .{ .name = .{ Schema, .gateway_name }, ... }
///   .on_scan   = hook, a `fn (zom.Scan) void`, set on every relation
///
/// Gateways are initialised in declaration order and deinitialised in
/// reverse.
pub fn Container(comptime spec: anytype) type {
    const gateway_fields = specFields(spec, "gateways");
    const relation_fields = specFields(spec, "relations");
    const scan_hook = scanHook(spec);

    var gateway_names: [gateway_fields.len][]const u8 = undefined;
    var gateway_types: [gateway_fields.len]type = undefined;
    var config_types: [gateway_fields.len]type = undefined;
    var config_attrs: [gateway_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (gateway_fields, 0..) |f, i| {
        const G = @field(spec.gateways, f.name);
        if (@TypeOf(G) != type)
            @compileError("zom: container gateway '" ++ f.name ++ "' must be a gateway type, found a value of type `" ++ @typeName(@TypeOf(G)) ++ "`");
        _ = adapter.Adapter(G);
        gateway_names[i] = f.name;
        gateway_types[i] = G;
        config_types[i] = G.Config;
        config_attrs[i] = .{ .default_value_ptr = defaultConfig(G.Config) };
    }

    var relation_names: [relation_fields.len][]const u8 = undefined;
    var relation_types: [relation_fields.len]type = undefined;
    var relation_gateways: [relation_fields.len][]const u8 = undefined;
    for (relation_fields, 0..) |f, i| {
        const entry = @field(spec.relations, f.name);
        const S, const gateway = relationEntry(f.name, entry);
        const g = gatewayIndex(&gateway_names, f.name, gateway);
        relation_names[i] = f.name;
        relation_types[i] = Relation(S, gateway_types[g]);
        relation_gateways[i] = gateway;
    }

    // The struct below can only refer to comptime values that are no longer
    // mutable, so freeze the arrays.
    const gateway_names_final = gateway_names;
    const gateway_types_final = gateway_types;
    const config_types_final = config_types;
    const config_attrs_final = config_attrs;
    const relation_names_final = relation_names;
    const relation_types_final = relation_types;
    const relation_gateways_final = relation_gateways;

    return struct {
        const Self = @This();

        /// One field per gateway, e.g. `default: zom.memory.Gateway`.
        pub const Gateways = @Struct(.auto, null, &gateway_names_final, &gateway_types_final, &@splat(.{}));
        /// One field per relation, each a `zom.Relation(Schema, Gateway)`.
        pub const Relations = @Struct(.auto, null, &relation_names_final, &relation_types_final, &@splat(.{}));
        /// One field per gateway, each its `Gateway.Config`. A field has a
        /// default when every field of that `Config` has one, so a
        /// container whose gateways need no settings takes `.{}`.
        pub const Config = @Struct(.auto, null, &gateway_names_final, &config_types_final, &config_attrs_final);

        gateways: Gateways,
        relations: Relations,

        /// Initialises every gateway in declaration order, then builds every
        /// relation. If anything fails, the gateways initialised so far are
        /// deinitialised again, in reverse order, and `self` is left
        /// undefined. `self` must stay where it is until `deinit`: see
        /// "Pointer stability" at the top of this file.
        pub fn init(self: *Self, allocator: Allocator, config: Config) !void {
            var initialised: usize = 0;
            errdefer deinitFirst(&self.gateways, initialised);

            inline for (gateway_names_final, gateway_types_final) |name, G| {
                @field(self.gateways, name) = try initGateway(G, allocator, @field(config, name));
                initialised += 1;
            }
            inline for (relation_names_final, relation_types_final, relation_gateways_final) |name, R, gateway| {
                @field(self.relations, name) = try R.init(&@field(self.gateways, gateway));
                @field(self.relations, name).on_scan = scan_hook;
            }
        }

        /// Sets `ctx` on every relation whose schema has plugins (see
        /// plugins.zig), e.g. `app.setPluginContext(.{ .clock = .{ .io = io } })`
        /// after `init`. Relations copied out before the call, such as a
        /// `Repository`'s, keep the context they had.
        pub fn setPluginContext(self: *Self, ctx: plugins.Context) void {
            inline for (relation_names_final, relation_types_final) |name, R| {
                if (R.PluginContext != void) @field(self.relations, name).plugin_context = ctx;
            }
        }

        /// Deinitialises every gateway in reverse declaration order.
        /// Relations, and rows read through them, must not be used after.
        pub fn deinit(self: *Self) void {
            deinitFirst(&self.gateways, gateway_names_final.len);
            self.* = undefined;
        }

        /// Deinitialises the first `n` gateways, last first.
        fn deinitFirst(gateways: *Gateways, n: usize) void {
            inline for (0..gateway_names_final.len) |k| {
                const i = gateway_names_final.len - 1 - k;
                if (i < n) @field(gateways, gateway_names_final[i]).deinit();
            }
        }

        /// Runs `f(ctx, tx)` in a transaction on the gateway named
        /// `gateway`, through that gateway's own `transaction`: it commits
        /// when `f` returns and rolls back when `f` fails, returning `f`'s
        /// error. Zig has no closures, so `f`'s state comes in through
        /// `ctx`. Returns what `f` returns, with the gateway's errors added.
        ///
        /// `tx` is a `Relations`, the same type as `self.relations`, so code
        /// written against the container's relations takes it as well. The
        /// relations on `gateway` are rebound to the transaction (zom-pg's
        /// pinned connection, for instance), and the rest are copied from
        /// `self.relations` unchanged: they are not part of the transaction.
        /// The rebound relations are only valid inside `f`; don't keep them.
        ///
        /// A gateway without the `.transaction` capability, or a name that
        /// isn't one of the container's gateways, is a compile error.
        pub fn transaction(self: *Self, comptime gateway: @EnumLiteral(), ctx: anytype, comptime f: anytype) Transaction(gateway, @TypeOf(ctx), f) {
            const B = Bound(@tagName(gateway), @TypeOf(ctx), f);
            const g = &@field(self.gateways, @tagName(gateway));
            return g.transaction(B.Context{ .relations = &self.relations, .ctx = ctx }, B.run);
        }

        /// What `transaction(gateway, ctx, f)` returns: whatever the
        /// gateway's `transaction` makes of `f`'s result, usually that
        /// result with the gateway's errors merged in.
        pub fn Transaction(comptime gateway: @EnumLiteral(), comptime Ctx: type, comptime f: anytype) type {
            const G = TransactionGateway(@tagName(gateway));
            const B = Bound(@tagName(gateway), Ctx, f);
            return @TypeOf(@as(*G, undefined).transaction(@as(B.Context, undefined), B.run));
        }

        /// The type of the gateway called `name`, which must have the
        /// `.transaction` capability.
        fn TransactionGateway(comptime name: []const u8) type {
            for (gateway_names_final, gateway_types_final) |n, G| {
                if (!std.mem.eql(u8, n, name)) continue;
                if (!@hasDecl(G, "transaction"))
                    @compileError("zom: gateway '" ++ name ++ "' (adapter '" ++ G.adapter_name ++ "') does not support transactions: `container.transaction` needs the `transaction` capability (the gateway has no `transaction`)");
                return G;
            }
            @compileError("zom: container.transaction names unknown gateway '" ++ name ++ "' (gateways: " ++ knownNames(&gateway_names_final) ++ ")");
        }

        /// The callback handed to the gateway's `transaction`: it rebuilds
        /// the relations on `gateway` over the transaction's `*G`, then
        /// calls `f(ctx, relations)`.
        fn Bound(comptime gateway: []const u8, comptime Ctx: type, comptime f: anytype) type {
            const G = TransactionGateway(gateway);
            // `@TypeOf` of the call rather than `@typeInfo(...).return_type`,
            // which is null when `f` is generic.
            const R = @TypeOf(f(@as(Ctx, undefined), @as(Relations, undefined)));
            var InitError = error{};
            for (relation_types_final, relation_gateways_final) |Rel, rg| {
                if (std.mem.eql(u8, rg, gateway))
                    InitError = InitError || @typeInfo(@TypeOf(Rel.init(@as(*G, undefined)))).error_union.error_set;
            }
            const Out = switch (@typeInfo(R)) {
                .error_union => |eu| (eu.error_set || InitError)!eu.payload,
                else => InitError!R,
            };
            return struct {
                const Context = struct { relations: *const Relations, ctx: Ctx };

                fn run(c: Context, tx: *G) Out {
                    var relations = c.relations.*;
                    inline for (relation_names_final, relation_types_final, relation_gateways_final) |name, Rel, rg| {
                        if (comptime std.mem.eql(u8, rg, gateway)) {
                            const outside = @field(relations, name);
                            @field(relations, name) = try Rel.init(tx);
                            @field(relations, name).on_scan = scan_hook;
                            @field(relations, name).plugin_context = outside.plugin_context;
                        }
                    }
                    return f(c.ctx, relations);
                }
            };
        }
    };
}

fn knownNames(comptime names: []const []const u8) []const u8 {
    if (names.len == 0) return "none";
    var known: []const u8 = "";
    for (names, 0..) |name, i| known = known ++ (if (i == 0) "" else ", ") ++ "'" ++ name ++ "'";
    return known;
}

/// `spec.on_scan`, a function or a pointer to one, or null when absent.
fn scanHook(comptime spec: anytype) ?rel.ScanHook {
    if (!@hasField(@TypeOf(spec), "on_scan")) return null;
    const hook = spec.on_scan;
    const H = @TypeOf(hook);
    if (H == fn (rel.Scan) void) return &hook;
    if (H == rel.ScanHook or H == *const fn (rel.Scan) void) return hook;
    @compileError("zom: Container `.on_scan` must be a `fn (zom.Scan) void`, found `" ++ @typeName(H) ++ "`");
}

/// `G.init` may return `G` or `!G`; this always returns `!G` so `init` can
/// `try` it either way.
fn initGateway(comptime G: type, allocator: Allocator, config: G.Config) !G {
    return G.init(allocator, config);
}

/// The fields of `spec.<name>`, which must be a struct literal.
fn specFields(comptime spec: anytype, comptime name: []const u8) []const std.builtin.Type.StructField {
    const Spec = @TypeOf(spec);
    if (@typeInfo(Spec) != .@"struct")
        @compileError("zom: Container expects `.{ .gateways = .{ ... }, .relations = .{ ... } }`, found `" ++ @typeName(Spec) ++ "`");
    if (!@hasField(Spec, name))
        @compileError("zom: Container spec is missing `." ++ name ++ "`");
    const T = @TypeOf(@field(spec, name));
    if (@typeInfo(T) != .@"struct")
        @compileError("zom: Container `." ++ name ++ "` must be a struct literal, found `" ++ @typeName(T) ++ "`");
    return @typeInfo(T).@"struct".fields;
}

/// Splits `.{ Schema, .gateway }` into the schema and the gateway's name.
fn relationEntry(comptime relation: []const u8, comptime entry: anytype) struct { type, []const u8 } {
    const usage = "zom: container relation '" ++ relation ++ "' must be `.{ Schema, .gateway_name }`";
    const E = @TypeOf(entry);
    const info = @typeInfo(E);
    if (info != .@"struct" or !info.@"struct".is_tuple or info.@"struct".fields.len != 2)
        @compileError(usage ++ ", found `" ++ @typeName(E) ++ "`");
    if (@TypeOf(entry[0]) != type)
        @compileError(usage ++ ": the first element must be a zom.Schema type");
    if (@TypeOf(entry[1]) != @TypeOf(.enum_literal))
        @compileError(usage ++ ": the second element must be an enum literal naming a gateway");
    return .{ entry[0], @tagName(entry[1]) };
}

fn gatewayIndex(comptime names: []const []const u8, comptime relation: []const u8, comptime gateway: []const u8) usize {
    for (names, 0..) |name, i| {
        if (std.mem.eql(u8, name, gateway)) return i;
    }
    @compileError("zom: container relation '" ++ relation ++ "' names unknown gateway '" ++ gateway ++ "' (gateways: " ++ knownNames(names) ++ ")");
}

/// A pointer to `C{}` when every field of `C` has a default, else null.
fn defaultConfig(comptime C: type) ?*const anyopaque {
    if (@typeInfo(C) != .@"struct") return null;
    for (@typeInfo(C).@"struct".fields) |f| {
        if (f.default_value_ptr == null) return null;
    }
    const value: C = .{};
    return @ptrCast(&value);
}
