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
//! Pointer stability: a relation holds a `*Dataset`, and the adapter contract
//! does not say where a dataset lives. The memory gateway heap-allocates its
//! datasets, but another gateway may keep one inside its own struct, and
//! then copying the gateway would leave the relation pointing at the old
//! copy. So `init` fills the container in place (`self: *Self`) instead of
//! returning it by value, and a container must not be copied or moved
//! between `init` and `deinit`.

const std = @import("std");
const adapter = @import("adapter.zig");
const Relation = @import("relation.zig").Relation;
const Allocator = std.mem.Allocator;

/// `spec` is an anonymous struct literal with two fields:
///
///   .gateways  = .{ .name = GatewayType, ... }
///   .relations = .{ .name = .{ Schema, .gateway_name }, ... }
///
/// Gateways are initialised in declaration order and deinitialised in
/// reverse.
pub fn Container(comptime spec: anytype) type {
    const gateway_fields = specFields(spec, "gateways");
    const relation_fields = specFields(spec, "relations");

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
    };
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
    var known: []const u8 = "";
    for (names, 0..) |name, i| known = known ++ (if (i == 0) "" else ", ") ++ "'" ++ name ++ "'";
    if (names.len == 0) known = "none";
    @compileError("zom: container relation '" ++ relation ++ "' names unknown gateway '" ++ gateway ++ "' (gateways: " ++ known ++ ")");
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
