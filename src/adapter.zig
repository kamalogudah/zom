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
//!     or insert(*Self, S.Tuple, std.mem.Allocator) !S.Tuple
//!   insertMany(*Self, []const S.Tuple) !usize        // .batch_insert
//!   update(*Self, Q, []const Q.Change) !usize        // .updatable
//!   delete(*Self, Q) !usize                          // .deletable
//!   pub const supports: zom.Supports                 // query features
//!   readProjected(*Self, Q, comptime P: type, std.mem.Allocator) ![]P
//!   pub fn filterable(comptime field: []const u8, comptime op: zom.Op) bool
//!   pub const strings: zom.StringOwnership           // .dataset when left out
//!
//! `strings` says who owns the strings in the tuples `read`, `readProjected`
//! and `insert` return (see strings.zig). With `.dataset` they point into
//! the dataset and the caller frees only the slice. With `.caller` they are
//! allocated with the allocator passed in, so `insert` must take one, and
//! every string attribute must be a slice. Callers free either kind the same
//! way, with the relation's `free` and `freeOne`.
//!
//! `readProjected` is required when `supports.projection` is true: it reads
//! the rows `read` would, as `P`, a `zom.Project(S.Tuple, ...)` struct with
//! some of the tuple's fields (copy them by name, e.g. with `zom.Mapper`).
//! Without it, `select` reads whole tuples and zom maps them down.
//!
//! `filterable` narrows `supports` per attribute, for a backend that can only
//! filter on some of them (TigerBeetle's `query_transfers` filters on
//! `ledger` and `code`, not on `amount`). zom calls it at compile time with
//! a field name and an op that `supports` already allows; returning false
//! makes that filter unsupported. Without it, every attribute is filterable.
//!
//! A relation that uses a feature the dataset does not support is a compile
//! error in `.strict` mode (the default), or evaluated in memory after the
//! supported part in `.fallback` mode (see relation.zig).
//!
//! `self` may be taken by value, `*Self` or `*const Self`.

const std = @import("std");
const q = @import("query.zig");
const strings = @import("strings.zig");
pub const StringOwnership = strings.StringOwnership;

/// The query features a dataset can evaluate itself. A dataset declares
/// `pub const supports: zom.Supports = ...;`, setting only what it handles;
/// one that declares nothing gets the defaults. A strict relation refuses to
/// compile a query that uses a feature left out here, and a fallback
/// relation evaluates it in memory; `zom.lint` skips the checks for the
/// features a dataset does not support. Filters with ops that have no flag
/// (`eq` .. `gte`, `between`, `is_null`, `is_not_null`) are always
/// supported, unless the dataset's `filterable` says otherwise.
pub const Supports = struct {
    /// Boolean groups: `whereAny`, `whereNot`, and `zom.any` / `zom.all` /
    /// `zom.not` inside them. Without it, a dataset only gets queries whose
    /// filters are all AND-ed, which it reads through `filterSlice()`.
    @"or": bool = false,
    /// `.in` and `.not_in` filters: the attribute is (not) one of a list of
    /// values. Also `whereIn` and `whereNotIn`.
    in: bool = false,
    /// `.like` and `.ilike` filters: pattern matching on strings.
    like: bool = false,
    /// Ordering by any attribute. Without it, only the primary key.
    order_on: bool = true,
    /// Skipping rows with `offset`.
    offset: bool = true,
    /// Reading only some attributes (`select`), through `readProjected`.
    /// When false, `select` still works: zom reads whole tuples and maps
    /// them down.
    projection: bool = false,
    /// Joining another dataset: `relation.join(.assoc)` and `whereJoined`,
    /// which set `query.join` (a `zom.Join`). A dataset with it must read
    /// that join in `read` and `count`: keep only the rows with at least one
    /// row of the joined dataset matching the join's keys and filters, each
    /// once. It is never evaluated in memory, so a relation without it can't
    /// join even in `.fallback` mode. Writes never see a join (they return
    /// `error.JoinedWrite` first).
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

        /// Null when the dataset for `S` can evaluate a `field op ...`
        /// filter itself, else why not, for an error message.
        pub fn filterGap(comptime S: type, comptime field: []const u8, comptime op: q.Op) ?[]const u8 {
            const s = supports(S);
            switch (op) {
                .in, .not_in => if (!s.in) return "`.in` and `.not_in` filters need `supports.in`",
                .like, .ilike => if (!s.like) return "`.like` and `.ilike` filters need `supports.like`",
                else => {},
            }
            const D = Dataset(S);
            if (@hasDecl(D, "filterable") and !D.filterable(field, op))
                return "its dataset's `filterable` rejects `." ++ @tagName(op) ++ "` on '" ++ field ++ "'";
            return null;
        }

        /// Null when the dataset for `S` can order by `field`, else why not.
        pub fn orderGap(comptime S: type, comptime field: []const u8) ?[]const u8 {
            if (supports(S).order_on or std.mem.eql(u8, field, @tagName(S.primary_key))) return null;
            return "`supports.order_on` is false, so it only orders by the primary key '" ++ @tagName(S.primary_key) ++ "'";
        }

        /// The dataset's `strings`, or `.dataset` when it declares none.
        pub fn stringOwnership(comptime S: type) StringOwnership {
            const D = Dataset(S);
            return if (@hasDecl(D, "strings")) D.strings else .dataset;
        }

        /// True when the dataset's `insert` takes an allocator for the
        /// strings of the tuple it returns.
        pub fn insertTakesAllocator(comptime S: type) bool {
            const D = Dataset(S);
            if (!@hasDecl(D, "insert")) return false;
            return @typeInfo(@TypeOf(D.insert)).@"fn".params.len == 3;
        }

        pub fn has(comptime S: type, comptime cap: Capability) bool {
            return @field(capabilities(S), @tagName(cap));
        }

        /// True when the dataset for `S` has none of `insert`, `insertMany`,
        /// `update` and `delete`.
        pub fn readOnly(comptime S: type) bool {
            const caps = capabilities(S);
            return !(caps.writable or caps.batch_insert or caps.updatable or caps.deletable);
        }

        /// A compile error naming the adapter and relation when the adapter
        /// lacks `cap` for `S`. `method` is what the caller tried to use,
        /// e.g. "create". Because Zig only analyses a function when it is
        /// called, calling this from a method makes only that method fail.
        pub fn require(comptime S: type, comptime cap: Capability, comptime method: []const u8) void {
            requireAny(S, &.{cap}, method);
        }

        /// Like `require`, but any one of `caps` is enough, e.g.
        /// `createMany` runs on `insertMany` or, failing that, `insert`.
        /// `caps` must all be dataset capabilities or all be `.transaction`.
        pub fn requireAny(comptime S: type, comptime caps: []const Capability, comptime method: []const u8) void {
            for (caps) |cap| if (has(S, cap)) return;
            const on_gateway = caps[0] == .transaction;
            var tags: []const u8 = "";
            var decls: []const u8 = "";
            for (caps, 0..) |cap, i| {
                const sep = if (i == 0) "" else " or ";
                tags = tags ++ sep ++ "`" ++ @tagName(cap) ++ "`";
                decls = decls ++ sep ++ "`" ++ declFor(cap) ++ "`";
            }
            const problem = if (!on_gateway and readOnly(S))
                std.fmt.comptimePrint("is read-only for relation '{s}'", .{S.name})
            else
                std.fmt.comptimePrint("does not support `{s}` for relation '{s}'", .{ method, S.name });
            @compileError(std.fmt.comptimePrint("zom: adapter '{s}' {s}: `{s}` needs the {s} capability ({s} has no {s})", .{
                name,
                problem,
                method,
                tags,
                if (on_gateway) "gateway" else "dataset",
                decls,
            }));
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
    var ownership: StringOwnership = .dataset;
    if (@hasDecl(D, "strings")) {
        if (@TypeOf(D.strings) != StringOwnership) {
            problems = problems ++ "\n  - `strings` must be a `zom.StringOwnership`, found `" ++ @typeName(@TypeOf(D.strings)) ++ "`";
        } else {
            ownership = D.strings;
        }
    }
    if (ownership == .caller) {
        for (@typeInfo(T).@"struct".fields) |f| {
            if (strings.isStringField(f.type) and !strings.isFreeableString(f.type))
                problems = problems ++ "\n  - `strings` is `.caller`, so '" ++ f.name ++ "' must be a slice such as []const u8, found `" ++
                    @typeName(f.type) ++ "`";
        }
    }
    const insert_plain: Signature = .{
        .params = &.{T},
        .returns = .{ .fallible = T },
        .text = "fn (*Self, Tuple) !Tuple",
    };
    const insert_alloc: Signature = .{
        .params = &.{ T, std.mem.Allocator },
        .returns = .{ .fallible = T },
        .text = "fn (*Self, Tuple, std.mem.Allocator) !Tuple",
    };
    if (@hasDecl(D, "insert")) {
        const F = @TypeOf(D.insert);
        if (ownership == .caller) {
            if (!matches(D, F, insert_alloc))
                problems = problems ++ "\n  - `strings` is `.caller`, so `insert` must be `" ++ insert_alloc.text ++
                    "` (the allocator owns the returned strings), found `" ++ fnName(F) ++ "`";
        } else if (!matches(D, F, insert_plain) and !matches(D, F, insert_alloc)) {
            problems = problems ++ "\n  - `insert` must be `" ++ insert_plain.text ++ "` or `" ++ insert_alloc.text ++
                "`, found `" ++ fnName(F) ++ "`";
        }
    }
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
    var projection = false;
    if (@hasDecl(D, "supports")) {
        if (@TypeOf(D.supports) != Supports) {
            problems = problems ++ "\n  - `supports` must be a `zom.Supports`, found `" ++ @typeName(@TypeOf(D.supports)) ++ "`";
        } else {
            projection = D.supports.projection;
        }
    }
    if (projection and !@hasDecl(D, "readProjected")) {
        problems = problems ++ "\n  - `supports.projection` is true, but there is no `pub fn readProjected`";
    } else {
        // Generic in P, so the return type can't be checked.
        problems = problems ++ checkMethod(D, "readProjected", false, .{
            .params = &.{ Q, type, std.mem.Allocator },
            .text = "fn (*Self, zom.Query(Tuple), comptime P: type, std.mem.Allocator) ![]P",
        });
    }

    problems = problems ++ checkMethod(D, "filterable", false, .{
        .self = false,
        .params = &.{ []const u8, q.Op },
        .returns = .{ .exactly = bool },
        .text = "fn (comptime field: []const u8, comptime op: zom.Op) bool",
    });

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
