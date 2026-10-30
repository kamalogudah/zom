//! Adapter = the v1 adapter contract (plan.md section 3.1).
//!
//! rom finds out what an adapter can do at runtime, when a command is built.
//! zom reads it off the gateway's declarations at compile time: the required
//! ones are checked (presence and, where it can, signature), and the optional
//! ones become capabilities. Every problem is collected first and reported in
//! one `@compileError`, so fixing an adapter is one round trip, not one per
//! missing declaration.
//!
//! A gateway must declare:
//!
//!   pub const adapter_name = "memory";               // a string
//!   pub const Config = struct { ... };               // what init takes
//!   pub fn init(std.mem.Allocator, Config) Gateway   // or !Gateway
//!   pub fn deinit(*Gateway) void
//!   pub fn Dataset(comptime S: type) type            // S is a zom.Schema
//!   pub fn dataset(*Gateway, comptime S: type) !*Dataset(S)
//!
//! and may declare `transaction` (capability `.transaction`). With
//! `Q = zom.Query(S.Tuple)`, a dataset must declare:
//!
//!   read(*Self, Q, std.mem.Allocator) ![]S.Tuple
//!   count(*Self, Q) !usize
//!
//! and may declare:
//!
//!   insert(*Self, S.Tuple) !S.Tuple                  // .writable
//!   insertMany(*Self, []const S.Tuple) !usize        // .batch_insert
//!   update(*Self, Q, []const Q.Change) !usize        // .updatable
//!   delete(*Self, Q) !usize                          // .deletable
//!   pub const supports: zom.Supports                 // query features
//!
//! `self` may be taken by value, `*Self` or `*const Self`.

const std = @import("std");
const q = @import("query.zig");

/// The query features a dataset can evaluate itself. A dataset declares
/// `pub const supports: zom.Supports = ...;`, setting only what it handles;
/// one that declares nothing gets the defaults. Relations do not check this
/// yet (plan.md Phase 3).
pub const Supports = struct {
    /// Filters combined with `or`.
    @"or": bool = false,
    /// `.in` filters: the attribute is one of a list of values.
    in: bool = false,
    /// `.like` filters: pattern matching on strings.
    like: bool = false,
    /// Ordering by any attribute, not only the primary key.
    order_on: bool = true,
    /// Skipping rows with `offset`.
    offset: bool = true,
    /// Reading only some attributes (`select`).
    projection: bool = false,
    /// Joining another dataset.
    join: bool = false,

    /// Every feature, e.g. for an adapter that evaluates queries in memory.
    pub const all: Supports = .{
        .@"or" = true,
        .in = true,
        .like = true,
        .order_on = true,
        .offset = true,
        .projection = true,
        .join = true,
    };
};

/// The error names every adapter must use for the same condition (plan.md
/// section 3.1), so callers can handle them the same way whatever the
/// adapter. An adapter may return other errors too; these names are only
/// reserved for these conditions.
pub const Error = error{
    /// `insert` or `insertMany` was given a tuple whose primary key is
    /// already stored, or `update` would set the primary key to one in use
    /// (or to the same key on more than one tuple).
    DuplicatePrimaryKey,
    /// A runtime value does not fit the attribute it is written to, e.g. 300
    /// for a `u8`.
    ValueOutOfRange,
    /// The adapter looked up one tuple by key, as its backend requires, and
    /// there is none. A query that matches nothing is not an error: `read`
    /// returns an empty slice and `count` returns 0.
    NotFound,
    /// The backend refuses writes at runtime, e.g. a database opened
    /// read-only or a replica. An adapter that can never write leaves out
    /// `insert`, `update` and `delete` instead, which is a compile error.
    ReadOnly,
    /// The adapter cannot reach its backend: connecting failed, or the
    /// connection was lost.
    ConnectionFailed,
};

pub const Capability = enum { writable, batch_insert, updatable, deletable, transaction };

/// One bool per `Capability`: `caps.writable`, `caps.transaction`, ...
pub const Capabilities = std.enums.EnumFieldStruct(Capability, bool, false);

/// The declaration that gives each capability.
fn declFor(comptime cap: Capability) []const u8 {
    return switch (cap) {
        .writable => "insert",
        .batch_insert => "insertMany",
        .updatable => "update",
        .deletable => "delete",
        .transaction => "transaction",
    };
}

/// Checks `G` against the gateway contract and returns its adapter. The
/// dataset contract depends on the schema, so it is checked per schema, by
/// `Dataset(S)`.
pub fn Adapter(comptime G: type) type {
    comptime checkGateway(G);

    return struct {
        pub const Gateway = G;
        pub const name: []const u8 = G.adapter_name;

        /// `G.Dataset(S)`, checked against the dataset contract.
        pub fn Dataset(comptime S: type) type {
            comptime checkDataset(G, S);
            return G.Dataset(S);
        }

        pub fn capabilities(comptime S: type) Capabilities {
            const D = Dataset(S);
            var caps: Capabilities = .{};
            inline for (comptime std.enums.values(Capability)) |cap| {
                const Owner = if (cap == .transaction) G else D;
                @field(caps, @tagName(cap)) = @hasDecl(Owner, declFor(cap));
            }
            return caps;
        }

        /// The dataset's `supports`, or the defaults when it declares none.
        pub fn supports(comptime S: type) Supports {
            const D = Dataset(S);
            return if (@hasDecl(D, "supports")) D.supports else .{};
        }

        pub fn has(comptime S: type, comptime cap: Capability) bool {
            return @field(capabilities(S), @tagName(cap));
        }

        /// A compile error naming the adapter when it lacks `cap` for `S`.
        /// `method` is what the caller tried to use, e.g. "create".
        pub fn require(comptime S: type, comptime cap: Capability, comptime method: []const u8) void {
            if (has(S, cap)) return;
            const owner = if (cap == .transaction) "gateway" else "dataset";
            @compileError("zom: adapter '" ++ name ++ "' is not ." ++ @tagName(cap) ++ ", so `" ++ method ++
                "` is not available on " ++ S.name ++ " (its " ++ owner ++ " has no `" ++ declFor(cap) ++ "`)");
        }
    };
}

fn checkGateway(comptime G: type) void {
    if (!isContainer(G))
        @compileError("zom: gateway '" ++ @typeName(G) ++ "' must be a struct, found " ++ @tagName(@typeInfo(G)));

    var problems: []const u8 = "";

    if (!@hasDecl(G, "adapter_name")) {
        problems = problems ++ "\n  - missing `pub const adapter_name`";
    } else if (!q.isString(@TypeOf(G.adapter_name))) {
        problems = problems ++ "\n  - `adapter_name` must be a string, found `" ++ @typeName(@TypeOf(G.adapter_name)) ++ "`";
    }

    // Without a usable Config, init's second parameter is not checked.
    var config: ?type = null;
    if (!@hasDecl(G, "Config")) {
        problems = problems ++ "\n  - missing `pub const Config`";
    } else if (@TypeOf(G.Config) != type) {
        problems = problems ++ "\n  - `Config` must be a type, found `" ++ @typeName(@TypeOf(G.Config)) ++ "`";
    } else {
        config = G.Config;
    }

    problems = problems ++ checkMethod(G, "init", true, .{
        .self = false,
        .params = &.{ std.mem.Allocator, config },
        .returns = .{ .either = G },
        .text = "fn (std.mem.Allocator, Config) Gateway` or `!Gateway",
    });
    problems = problems ++ checkMethod(G, "deinit", true, .{
        .params = &.{},
        .returns = .{ .exactly = void },
        .text = "fn (*Gateway) void",
    });
    problems = problems ++ checkMethod(G, "Dataset", true, .{
        .self = false,
        .params = &.{type},
        .returns = .{ .exactly = type },
        .text = "fn (comptime S: type) type",
    });
    // The return type depends on S, so checkDataset checks it.
    problems = problems ++ checkMethod(G, "dataset", true, .{
        .params = &.{type},
        .text = "fn (*Gateway, comptime S: type) !*Dataset(S)",
    });
    problems = problems ++ checkMethod(G, "transaction", false, .{
        .params = null,
        .text = "fn (*Gateway, ...)",
    });

    if (problems.len > 0)
        @compileError("zom: gateway '" ++ @typeName(G) ++ "' does not satisfy the adapter contract:" ++ problems);
}

fn checkDataset(comptime G: type, comptime S: type) void {
    const D = G.Dataset(S);
    const header = "zom: dataset '" ++ @typeName(D) ++ "' of gateway '" ++ @typeName(G) ++
        "' does not satisfy the adapter contract:";
    if (!isContainer(D))
        @compileError(header ++ "\n  - `Dataset(S)` must return a struct, found " ++ @tagName(@typeInfo(D)));

    const T = S.Tuple;
    const Q = q.Query(T);
    var problems: []const u8 = "";

    const Got = @TypeOf(@as(*G, undefined).dataset(S));
    if (!isErrorUnionOf(Got, *D))
        problems = problems ++ "\n  - gateway `dataset` must return `!*Dataset(S)`, found `" ++ @typeName(Got) ++ "`";

    problems = problems ++ checkMethod(D, "read", true, .{
        .params = &.{ Q, std.mem.Allocator },
        .returns = .{ .fallible = []T },
        .text = "fn (*Self, zom.Query(Tuple), std.mem.Allocator) ![]Tuple",
    });
    problems = problems ++ checkMethod(D, "count", true, .{
        .params = &.{Q},
        .returns = .{ .fallible = usize },
        .text = "fn (*Self, zom.Query(Tuple)) !usize",
    });
    problems = problems ++ checkMethod(D, "insert", false, .{
        .params = &.{T},
        .returns = .{ .fallible = T },
        .text = "fn (*Self, Tuple) !Tuple",
    });
    problems = problems ++ checkMethod(D, "insertMany", false, .{
        .params = &.{[]const T},
        .returns = .{ .fallible = usize },
        .text = "fn (*Self, []const Tuple) !usize",
    });
    problems = problems ++ checkMethod(D, "update", false, .{
        .params = &.{ Q, []const Q.Change },
        .returns = .{ .fallible = usize },
        .text = "fn (*Self, zom.Query(Tuple), []const zom.Query(Tuple).Change) !usize",
    });
    problems = problems ++ checkMethod(D, "delete", false, .{
        .params = &.{Q},
        .returns = .{ .fallible = usize },
        .text = "fn (*Self, zom.Query(Tuple)) !usize",
    });
    if (@hasDecl(D, "supports") and @TypeOf(D.supports) != Supports)
        problems = problems ++ "\n  - `supports` must be a `zom.Supports`, found `" ++ @typeName(@TypeOf(D.supports)) ++ "`";

    if (problems.len > 0) @compileError(header ++ problems);
}

const Signature = struct {
    /// The first parameter is the owner, by value or pointer.
    self: bool = true,
    /// The parameters after `self`; null skips the check, and a null entry
    /// accepts any type.
    params: ?[]const ?type,
    returns: Returns = .any,
    /// The signature as shown in the error message.
    text: []const u8,
};

const Returns = union(enum) {
    any,
    exactly: type,
    fallible: type,
    /// `T` or `!T`.
    either: type,
};

/// Returns "" when `Owner.decl` is fine, else one problem line.
fn checkMethod(comptime Owner: type, comptime decl: []const u8, comptime required: bool, comptime sig: Signature) []const u8 {
    if (!@hasDecl(Owner, decl)) return if (required) "\n  - missing `pub fn " ++ decl ++ "`" else "";
    const F = @TypeOf(@field(Owner, decl));
    if (matches(Owner, F, sig)) return "";
    return "\n  - `" ++ decl ++ "` must be `" ++ sig.text ++ "`, found `" ++ fnName(F) ++ "`";
}

/// `@typeName`, except that an inferred error set prints as `!T` instead
/// of the long `@typeInfo(...)` expression the compiler uses for it.
fn fnName(comptime F: type) []const u8 {
    const f = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => return @typeName(F),
    };
    var out: []const u8 = "fn (";
    for (f.params, 0..) |p, i| {
        if (i > 0) out = out ++ ", ";
        out = out ++ if (p.is_generic) "comptime " else "";
        out = out ++ if (p.type) |P| @typeName(P) else "anytype";
    }
    out = out ++ ") ";
    const R = f.return_type orelse return out ++ "anytype";
    return out ++ switch (@typeInfo(R)) {
        .error_union => |e| if (std.mem.startsWith(u8, @typeName(e.error_set), "@typeInfo("))
            "!" ++ @typeName(e.payload)
        else
            @typeName(R),
        else => @typeName(R),
    };
}

fn matches(comptime Owner: type, comptime F: type, comptime sig: Signature) bool {
    const f = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        else => return false,
    };
    const skip: usize = @intFromBool(sig.self);
    if (f.params.len < skip) return false;
    if (sig.self) {
        if (f.params[0].type) |P| if (P != Owner and P != *Owner and P != *const Owner) return false;
    }
    if (sig.params) |params| {
        if (f.params.len != skip + params.len) return false;
        for (params, f.params[skip..]) |want, p| {
            const W = want orelse continue;
            const P = p.type orelse continue; // anytype
            if (P != W) return false;
        }
    }
    const R = f.return_type orelse return sig.returns == .any;
    return switch (sig.returns) {
        .any => true,
        .exactly => |T| R == T,
        .fallible => |T| isErrorUnionOf(R, T),
        .either => |T| R == T or isErrorUnionOf(R, T),
    };
}

fn isErrorUnionOf(comptime R: type, comptime T: type) bool {
    return switch (@typeInfo(R)) {
        .error_union => |e| e.payload == T,
        else => false,
    };
}

fn isContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => true,
        else => false,
    };
}
