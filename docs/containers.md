# Containers, repositories and plugins

## Container

`zom.Container(spec)` declares the gateways and the relations over them in
one place, like `ROM.container`. Each relation names its gateway with an enum
literal:

```zig
const UserSchema = zom.Schema(User, "users", .id, .{});
const PostSchema = zom.Schema(Post, "posts", .id, .{});

const App = zom.Container(.{
    .gateways = .{ .default = zom.memory.Gateway, .archive = zom.memory.Gateway },
    .relations = .{ .users = .{ UserSchema, .default }, .posts = .{ PostSchema, .archive } },
});

var app: App = undefined;
try app.init(allocator, .{});
defer app.deinit();

const users = app.relations.users;
_ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();
```

`App` has three generated struct types: `Gateways` (one field per gateway),
`Relations` (one `zom.Relation(Schema, Gateway)` per relation) and `Config`
(one `Gateway.Config` per gateway). A `Config` field defaults to `.{}` when
every field of that gateway's `Config` has a default, so `.{}` is enough for
memory gateways; any other gateway's settings must be passed, e.g.
`.{ .files = .{ .io = io, .path = "data/" } }`.

`init` initialises the gateways in declaration order, then builds each
relation. If a gateway or a relation fails, the gateways already initialised
are deinitialised, last first, and the error is returned. `deinit` also runs
in reverse order.

`app.transaction(.gateway, ctx, f)` runs `f(ctx, tx)` in that gateway's
transaction. Zig has no closures, so `f`'s state comes in through `ctx`. `tx`
is an `App.Relations`, the same type as `app.relations`: the relations on
`.gateway` are rebound to the transaction (zom-pg's pinned connection), and
the others are copied unchanged, so they are not part of it. `f` commits by
returning and rolls back by failing; its result or error comes back:

```zig
try app.transaction(.default, {}, struct {
    fn f(_: void, tx: App.Relations) !void {
        _ = try tx.users.create(.{ .id = 2, .name = "Otieno", .age = 24 }).commit();
        _ = try tx.users.byPk(1).update().set(.age, 32).commit();
    }
}.f);
```

A gateway without the `transaction` capability is a compile error:
`zom: gateway 'files' (adapter 'csv') does not support transactions`. The
memory gateway has one, so the same code runs in tests without Postgres.

`init` takes `self: *App` and fills it in place, and **the container must
not be copied or moved between `init` and `deinit`**. A relation holds a
pointer to its dataset, and the adapter contract lets a gateway keep its
datasets inside its own struct, where a copy would leave that pointer stale.
(The memory gateway heap-allocates its datasets, so it would survive a copy,
but other adapters need not.)

An optional `.on_scan = hook` in the spec, a `fn (zom.Scan) void`, is set on
every relation, and kept by relations chained from them, so every
`.fallback` read that runs in memory is reported in one place (see [Query
support](api.md#query-support-strict-and-fallback)).

A relation that names a gateway the container doesn't have, a relation that
isn't `.{ Schema, .gateway }`, and a gateway that fails `zom.Adapter` are all
compile errors.

[examples/csv_users](../examples/csv_users/src/main.zig) puts two adapters in
one container: users read from `data/users.csv` through `zom_csv.Gateway`,
posts held in `zom.memory.Gateway`, combined with `users.combine(.posts, posts)`. Run it
with `cd examples/csv_users && zig build run`; `zig build test` at the root
runs it too and checks its output.

## Repository

`zom.Repository(App, spec)` is rom-repository's root repository: it takes
the relations one part of the app needs from a container, and forwards
command shortcuts to its root relation:

```zig
const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users, .posts } });

var repo = UserRepo.init(&app);
_ = try repo.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();
const u = try repo.byPk(1).one(allocator);   // ?User
const n = try repo.relations.posts.count();
```

`byPk`, `where`, `all` (the whole root relation, to chain from), `create`,
`createMany`, `update` and `delete` each call the root relation's method of
the same name, so `repo.byPk(1).update()` and `repo.where(...).delete()`
work as on the relation. They are written out by hand, not mixed in, since
Zig 0.15 removed `usingnamespace`. A shortcut that needs a dataset capability
fails to compile, naming the adapter, exactly like the relation's own method,
and only when it is called: a repository over a read-only adapter compiles as
long as it is only read.

Custom views, rom's `def active = where(deleted_at: nil)`, go on a wrapper
struct with a `rel` field holding the container's relation. Name the wrapper
in `.relations`, and `.plain` for a relation without one:

```zig
const Users = struct {
    rel: @FieldType(App.Relations, "users"),

    pub fn active(self: Users) @TypeOf(self.rel) {
        return self.rel.where(.deleted_at, .eq, null);
    }
};

const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users, .posts = .plain } });

var repo = UserRepo.init(&app);
const active = try repo.relations.users.active().count();
const older = try repo.root().active().where(.age, .gt, 30).count();
```

Inside a [transaction](#container), build the repository from `tx` with
`fromRelations`, so its relations on that gateway run in the transaction:

```zig
try app.transaction(.default, {}, struct {
    fn f(_: void, tx: App.Relations) !void {
        const r = UserRepo.fromRelations(tx);
        _ = try r.create(.{ .id = 3, .name = "Otieno", .age = 24 }).commit();
    }
}.f);
```

`init(&app)` is `fromRelations(app.relations)`.
[examples/pg_repo](postgres-walkthrough.md#a-repository-and-a-transaction-on-postgres) does this
against Postgres.

`@TypeOf(self.rel)` lets a view return the relation's type without naming
it. The shortcuts still go to the relation itself (`rel`), not the wrapper.
`UserRepo.Relations`, `UserRepo.Root` (the root's wrapper or relation) and
`UserRepo.RootRelation` are the generated types.

A repository copies the container's relations (a dataset pointer and a
query each), so it is a cheap value; it must not be used after the
container's `deinit`. A relation the container lacks, a root that isn't in
`.relations`, a wrapper without a `rel` field of the right type, and a
relation named like one of the repository's own declarations (`create`,
`all`, `fromRelations`, ...) are compile errors.

## Plugins

A plugin is a comptime mixin listed on the schema. zom calls its hooks from
the changesets, in the order of `.plugins`. The first one is `timestamps`:

```zig
const Note = struct { id: u32, title: []const u8, created_at: i64 = 0, updated_at: i64 = 0 };
const NoteSchema = zom.Schema(Note, "notes", .id, .{
    .plugins = .{zom.plugins.timestamps(.{ .created = .created_at, .updated = .updated_at })},
});
const Notes = zom.Relation(NoteSchema, zom.memory.Gateway);

// The clock comes from the relation's plugin context, never from the
// plugin itself: `.{ .io = io }` in an app, a fixed time in tests.
const notes = (try Notes.init(&gw)).withPluginContext(.{ .clock = .{ .fixed = 1_700_000_000_000_000_000 } });

const note = try notes.create(.{ .id = 1, .title = "Draft" }).commit();
// note.created_at == note.updated_at == 1_700_000_000_000_000_000
_ = try notes.byPk(1).update().set(.title, "Final").commit(); // sets updated_at too
```

- Both fields must be `i64`, or `timestamps` gives a compile error naming
  the schema and the field. They count nanoseconds since the Unix epoch
  by default; pass `.unit = .seconds` (or `.milliseconds`,
  `.microseconds`) for other columns, and `.created = null` or
  `.updated = null` to set only one of them.
- Create sets both fields, overwriting what the tuple held. An update that
  changes something also sets `updated_at`, unless it sets it itself; an
  update with no changes stays a no-op. The extra change counts towards
  `max_changes` (16), so a 16th `set` makes `commit` return
  `error.TooManyChanges`.
- `createMany` runs `beforeCreate` on a copy of the borrowed rows, so it
  commits with `commitAlloc(allocator)`; plain `commit` is a compile error.
- In a container, `app.setPluginContext(.{ .clock = .{ .io = io } })` after
  `init` sets the context on every relation with plugins, and
  `app.transaction` keeps it. Without a clock, a timestamped commit panics
  with the relation's name.
- A schema without plugins pays nothing: its relation's `plugin_context`
  field is `void`, and the hooks are an `inline for` over an empty tuple.

### Writing a plugin

A plugin is any type with at least one of these declarations. zom finds
them with `@hasDecl`, so leave out the ones you don't need. `S` is the
schema, so one plugin works for every tuple:

```zig
const Frozen = struct {
    /// When the schema is analysed: reject schemas the plugin can't handle.
    pub fn validate(comptime S: type) void {
        if (!@hasField(S.Tuple, "id")) @compileError("Frozen needs an id");
    }
    /// On the tuple about to be inserted (a copy).
    pub fn beforeCreate(comptime S: type, tuple: *S.Tuple, ctx: *const zom.plugins.Context) void {
        _ = .{ tuple, ctx };
    }
    /// On the changes about to be applied. May return an error union, whose
    /// errors are added to `commit`'s.
    pub fn beforeUpdate(comptime S: type, changes: *zom.plugins.ChangeList(S.Tuple), ctx: *const zom.plugins.Context) error{Frozen}!void {
        _ = ctx;
        if (changes.find(.id) != null) return error.Frozen;
    }
};
```

`ChangeList` has `slice()`, `find(field)` and `append(field, value)`, which
type-checks the value like `set` and returns `error.TooManyChanges` when
full. A plugin may also declare the `before` and `after` hooks of
[Instrumentation](#instrumentation). A type in `.plugins` with none of
these declarations is a compile error, which catches a misspelt hook. Read
the time only through `ctx.clock`, so that tests stay deterministic.

### Instrumentation

A plugin with `before` and/or `after` hooks is called around every call
the relation and its changesets make to the dataset, for logging and
metrics. `zom.plugins.instrumentation.log` is a ready-made one:

```zig
const Event = zom.plugins.instrumentation.Event;
const Outcome = zom.plugins.instrumentation.Outcome;

// Counts the rows each read returns.
const RowCounter = struct {
    var rows_read: usize = 0;
    pub fn before(_: Event) void {}
    pub fn after(e: Event, o: Outcome) void {
        if (e.op == .read) rows_read += o.rows orelse 0;
    }
};

const Note = struct { id: u32, title: []const u8 };
const NoteSchema = zom.Schema(Note, "notes", .id, .{
    // Logs each call to `std.log.scoped(.zom)`: successes at .debug,
    // errors at .warn.
    .plugins = .{ zom.plugins.instrumentation.log(std.log.scoped(.zom)), RowCounter },
});
const notes = try zom.Relation(NoteSchema, zom.memory.Gateway).init(&gw);

_ = try notes.create(.{ .id = 1, .title = "Draft" }).commit(); // .insert, 1 row
const all = try notes.toSlice(allocator); // .read, 1 row
defer notes.free(allocator, all);
// RowCounter.rows_read == 1
```

- `Event` has `adapter` and `dataset` (names), `op` (`.read`, `.count`,
  `.insert`, `.insert_many`, `.update` or `.delete`) and `query`, the
  query handed to the dataset (null for inserts), which
  `event.queryOf(Note)` reads as a `*const zom.Query(Note)`.
- `Outcome` has `rows` (the slice length, the count, or 1 for an insert),
  `err` (the `@errorName` of the dataset's error, or null) and
  `duration_ns`. `after` runs on errors too, and the error still reaches
  the caller.
- The duration is measured with the plugin context's clock (see above),
  using the monotonic clock for `.{ .io = io }`. It is null when the
  relation has no clock, and exact with a `.func` test clock.
- What counts is dataset calls, not relation methods: `paginate` is a
  `.count` then a `.read`, a `createMany` without `insertMany` one
  `.insert` per row, and a `.fallback` read that filters in memory a
  `.read` whose `rows` is every row the dataset returned, the rows scanned.
- A schema without `before` or `after` pays nothing: each call's span is
  an empty struct, and nothing is measured or called. The hooks belong to
  the schema; a container cannot add them to schemas that lack them.
