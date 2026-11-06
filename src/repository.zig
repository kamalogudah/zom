//! Repository = rom-repository's `ROM::Repository::Root`.
//!
//! A repository groups the relations one part of an application needs, taken
//! from a `zom.Container`, around a root relation with command shortcuts:
//!
//!   const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users, .posts } });
//!   var repo = UserRepo.init(&app);       // or UserRepo.fromRelations(tx) in a transaction
//!   const u = try repo.byPk(1).one(allocator);
//!   _ = try repo.create(.{ ... }).commit();
//!   const n = try repo.relations.posts.count();
//!
//! Custom views, rom's `def active = where(...)`, live on a wrapper struct
//! around the container's relation, named in `.relations`:
//!
//!   const Users = struct {
//!       rel: @FieldType(App.Relations, "users"),
//!       pub fn active(self: Users) @TypeOf(self.rel) {
//!           return self.rel.where(.deleted_at, .eq, null);
//!       }
//!   };
//!   const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users, .posts = .plain } });
//!   repo.relations.users.active()
//!
//! The shortcuts (`byPk`, `where`, `all`, `create`, `createMany`, `update`,
//! `delete`) are written out by hand: Zig 0.15 removed `usingnamespace`, so
//! there is no way to mix the root relation's methods in. Each forwards to
//! the root relation (the wrapper's `rel`), so the ones that need a dataset
//! capability fail to compile, naming the adapter, exactly as the relation's
//! own method does. Like every Zig function, a shortcut is only analysed
//! when it is called, so a repository over a read-only adapter compiles as
//! long as only reads are used.
//!
//! A repository is a value: it copies the container's relations, which are
//! a dataset pointer and a query each, so it can be passed around freely.
//! It must not outlive the container's `deinit`.

const std = @import("std");
const q = @import("query.zig");
const changeset = @import("changeset.zig");

/// Method names a relation in `.relations` can't take, because the
/// repository struct declares them.
const reserved = [_][]const u8{ "init", "fromRelations", "root", "byPk", "where", "all", "create", "createMany", "update", "delete", "Relations", "Root", "RootRelation" };

/// `ContainerT` is a `zom.Container(...)` type. `spec` is an anonymous
/// struct literal:
///
///   .root      = .name, one of `.relations`
///   .relations = .{ .users, .posts }                    plain relations, or
///              = .{ .users = Users, .posts = .plain }   per relation, a
///                wrapper struct with a `rel` field of the container's
///                relation type, or `.plain` for the relation itself
pub fn Repository(comptime ContainerT: type, comptime spec: anytype) type {
    if (@TypeOf(ContainerT) != type or @typeInfo(ContainerT) != .@"struct" or !@hasDecl(ContainerT, "Relations"))
        @compileError("zom: Repository expects a zom.Container type as its first argument, found `" ++ @typeName(ContainerT) ++ "`");
    const ContainerRelations = ContainerT.Relations;
    const Spec = @TypeOf(spec);
    if (@typeInfo(Spec) != .@"struct")
        @compileError("zom: Repository expects `.{ .root = .name, .relations = .{ ... } }`, found `" ++ @typeName(Spec) ++ "`");
    if (!@hasField(Spec, "root")) @compileError("zom: Repository spec is missing `.root`");
    if (!@hasField(Spec, "relations")) @compileError("zom: Repository spec is missing `.relations`");
    if (@TypeOf(spec.root) != @TypeOf(.enum_literal))
        @compileError("zom: Repository `.root` must be an enum literal naming a relation, found `" ++ @typeName(@TypeOf(spec.root)) ++ "`");
    for (@typeInfo(Spec).@"struct".fields) |f| {
        if (!std.mem.eql(u8, f.name, "root") and !std.mem.eql(u8, f.name, "relations"))
            @compileError("zom: Repository spec has unknown option `." ++ f.name ++ "` (options: `.root`, `.relations`)");
    }

    const entries = relationEntries(ContainerRelations, spec.relations);
    const root_name = @tagName(spec.root);

    var names: [entries.len][]const u8 = undefined;
    var types: [entries.len]type = undefined;
    var wrapped: [entries.len]bool = undefined;
    var root_index: ?usize = null;
    for (entries, 0..) |e, i| {
        names[i] = e.name;
        types[i] = e.T;
        wrapped[i] = e.wrapped;
        if (std.mem.eql(u8, e.name, root_name)) root_index = i;
    }
    const ri = root_index orelse
        @compileError("zom: repository root '" ++ root_name ++ "' is not one of its relations (relations: " ++ list(&names) ++ ")");

    const names_final = names;
    const types_final = types;
    const wrapped_final = wrapped;

    return struct {
        const Self = @This();

        /// One field per relation in `.relations`: the container's
        /// relation, or the wrapper struct holding it in `rel`.
        pub const Relations = @Struct(.auto, null, &names_final, &types_final, &@splat(.{}));
        /// The root entry's type: its wrapper, or the relation itself.
        pub const Root = types_final[ri];
        /// The root relation the shortcuts forward to.
        pub const RootRelation = @FieldType(ContainerRelations, root_name);

        relations: Relations,

        /// Copies the listed relations out of an initialised container.
        pub fn init(container: *const ContainerT) Self {
            return fromRelations(container.relations);
        }

        /// Builds the repository from a container's `Relations` value
        /// rather than the container: inside `app.transaction(.gw, ctx, f)`,
        /// `UserRepo.fromRelations(tx)` gives a repository whose relations
        /// on `.gw` run in the transaction.
        pub fn fromRelations(relations: ContainerRelations) Self {
            var self: Self = undefined;
            inline for (names_final, types_final, wrapped_final) |name, T, w| {
                const r = @field(relations, name);
                @field(self.relations, name) = if (w) T{ .rel = r } else r;
            }
            return self;
        }

        /// The root entry, wrapper included, for its custom views:
        /// `repo.root().active()`.
        pub fn root(self: Self) Root {
            return @field(self.relations, root_name);
        }

        fn rootRelation(self: Self) RootRelation {
            return if (wrapped_final[ri]) self.root().rel else self.root();
        }

        // -- root shortcuts -----------------------------------------------
        //
        // Written out by hand: no `usingnamespace` since Zig 0.15.

        /// The whole root relation, to chain from: `repo.all().order(...)`.
        pub fn all(self: Self) RootRelation {
            return self.rootRelation();
        }

        pub fn byPk(self: Self, value: anytype) RootRelation {
            return self.rootRelation().byPk(value);
        }

        pub fn where(self: Self, comptime field: RootRelation.Field, comptime op: q.Op, value: anytype) RootRelation {
            return self.rootRelation().where(field, op, value);
        }

        pub fn create(self: Self, tuple: RootRelation.Tuple) changeset.Create(RootRelation) {
            return self.rootRelation().create(tuple);
        }

        pub fn createMany(self: Self, tuples: []const RootRelation.Tuple) changeset.CreateMany(RootRelation) {
            return self.rootRelation().createMany(tuples);
        }

        /// An update of every row of the root relation: narrow it first
        /// with `repo.byPk(id).update()` or `repo.where(...).update()` to
        /// change fewer.
        pub fn update(self: Self) changeset.Update(RootRelation) {
            return self.rootRelation().update();
        }

        /// Deletes every row of the root relation (an adapter like zom-sql
        /// refuses an unfiltered delete unless the query says `all`); use
        /// `repo.byPk(id).delete()` for one.
        pub fn delete(self: Self) !usize {
            return self.rootRelation().delete();
        }
    };
}

const Entry = struct { name: []const u8, T: type, wrapped: bool };

/// Reads `.relations`, a tuple of enum literals or a struct of wrappers.
fn relationEntries(comptime ContainerRelations: type, comptime relations: anytype) []const Entry {
    const R = @TypeOf(relations);
    const info = @typeInfo(R);
    if (info != .@"struct")
        @compileError("zom: Repository `.relations` must be `.{ .users, .posts }` or `.{ .users = Wrapper, .posts = .plain }`, found `" ++ @typeName(R) ++ "`");
    const fields = info.@"struct".fields;
    var out: [fields.len]Entry = undefined;
    for (fields, 0..) |f, i| {
        const value = @field(relations, f.name);
        const name = if (info.@"struct".is_tuple) blk: {
            if (@TypeOf(value) != @TypeOf(.enum_literal))
                @compileError("zom: Repository `.relations` element " ++ f.name ++ " must be an enum literal naming a relation, found `" ++ @typeName(@TypeOf(value)) ++ "`");
            break :blk @tagName(value);
        } else f.name;
        const Rel = containerRelation(ContainerRelations, name);
        for (out[0..i]) |prev| {
            if (std.mem.eql(u8, prev.name, name)) @compileError("zom: repository relation '" ++ name ++ "' is listed twice");
        }
        for (reserved) |r| {
            if (std.mem.eql(u8, r, name))
                @compileError("zom: repository relation '" ++ name ++ "' clashes with the repository's own `" ++ r ++ "`");
        }
        out[i] = if (info.@"struct".is_tuple) .{ .name = name, .T = Rel, .wrapped = false } else wrapperEntry(name, Rel, value);
    }
    const final = out;
    return &final;
}

fn wrapperEntry(comptime name: []const u8, comptime Rel: type, comptime value: anytype) Entry {
    const V = @TypeOf(value);
    if (V == @TypeOf(.enum_literal)) {
        if (value != .plain)
            @compileError("zom: repository relation '" ++ name ++ "' must be a wrapper struct type or `.plain`, found `." ++ @tagName(value) ++ "`");
        return .{ .name = name, .T = Rel, .wrapped = false };
    }
    if (V != type or @typeInfo(value) != .@"struct")
        @compileError("zom: repository relation '" ++ name ++ "' must be a wrapper struct type or `.plain`, found a value of type `" ++ @typeName(V) ++ "`");
    if (!@hasField(value, "rel"))
        @compileError("zom: repository wrapper `" ++ @typeName(value) ++ "` for relation '" ++ name ++ "' needs a `rel` field of type `" ++ @typeName(Rel) ++ "`");
    if (@FieldType(value, "rel") != Rel)
        @compileError("zom: repository wrapper `" ++ @typeName(value) ++ "` for relation '" ++ name ++ "': `rel` must be `" ++ @typeName(Rel) ++ "`, found `" ++ @typeName(@FieldType(value, "rel")) ++ "`");
    return .{ .name = name, .T = value, .wrapped = true };
}

fn containerRelation(comptime ContainerRelations: type, comptime name: []const u8) type {
    if (@hasField(ContainerRelations, name)) return @FieldType(ContainerRelations, name);
    const fields = @typeInfo(ContainerRelations).@"struct".fields;
    var names: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| names[i] = f.name;
    @compileError("zom: repository relation '" ++ name ++ "' is not in the container (relations: " ++ list(&names) ++ ")");
}

fn list(comptime names: []const []const u8) []const u8 {
    if (names.len == 0) return "none";
    var out: []const u8 = "";
    for (names, 0..) |n, i| out = out ++ (if (i == 0) "" else ", ") ++ "'" ++ n ++ "'";
    return out;
}
