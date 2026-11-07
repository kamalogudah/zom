# zom

A [rom-rb](https://github.com/hanakai-rb/rom) style data mapping toolkit for Zig 0.16.

rom's core idea carries over directly: persistence is split into small layers
that each do one thing, and nothing is an "active record".

| ROM (Ruby)                                 | zom                                                            |
|--------------------------------------------|----------------------------------------------------------------|
| `ROM::Gateway` / adapter                   | `zom.memory.Gateway` (any type that passes `zom.Adapter`)      |
| dataset                                    | `Gateway.Dataset(Schema)`: `read`, `count`, and optionally `insert`, `insertMany`, `update`, `delete` |
| `schema(:users) do attribute ... end`      | `zom.Schema(UserTuple, "users", .id, .{})`                     |
| `ROM::Relation`                            | `zom.Relation(Schema, Gateway)`, an immutable value             |
| `users.where(...).order(...).limit(...)`   | `users.where(.age, .gt, 25).order(.name, .asc).limit(10)`      |
| `users.by_pk(1).one`                       | `users.byPk(1).one(allocator)`                                 |
| `users.changeset(:create, data).commit`    | `users.create(tuple).map(f).commit()`                          |
| `users.changeset(:create, [a, b]).commit`  | `users.createMany(&.{ a, b }).commit()`                        |
| `posts.changeset(:create, data).associate(user)` | `posts.associate(.author, user).create(data).commit()` (see [Associated creates](#associated-creates)) |
| `users.by_pk(1).changeset(:update, ...)`   | `users.byPk(1).update().set(.email, "...").commit()`           |
| `command(:delete)`                         | `try users.where(...).delete()`                                |
| `ROM::Mapper`, `map_with`, `map_to`        | `zom.Mapper(Tuple, Entity, .{ .renames = ... })`, `mapWith`, `mapTo` |
| `users.combine(:posts)`                    | `users.combine(.posts, posts).mapTo(Author, allocator)` (see [Associations](#associations)) |
| `users.join(:posts).where(posts[:published] => true)` | `users.join(.posts).whereJoined(.posts, .published, .eq, true)` (see [Join](#join)) |
| rom-sql (Sequel)                           | `zom_sql.compileRelation(.postgres, allocator, rel)` and `compileInsert` / `compileUpdate` / `compileDelete` in [zom-sql](#zom-sql), a SQL compiler with no driver yet |

## What Zig gives you for free

- **Schemas are structs.** Types, optionality (`?i64`) and defaults come from the
  tuple struct, so there is no attribute DSL.
- **Type checks at compile time.** `users.where(.age, .eq, "old")` does not
  compile: `type mismatch on 'age': attribute is u8, got *const [3:0]u8`.
  `null` is only accepted for optional attributes, and field names are enum
  literals, so typos fail at compile time too. Literal values are checked as
  well: `.set(.role, .admn)` and `.set(.age, 300)` on a `u8` do not compile.
  A runtime value that does not fit returns `error.ValueOutOfRange`.
- **Queries don't allocate.** Filters and changes live in fixed-capacity
  arrays (16 each). This follows Tiger Style: limits are explicit and
  asserted.
- **The adapter seam is a comptime contract.** A relation never runs anything
  itself; it builds a `Query(T)` value, and the adapter interprets it. The same
  relation can be evaluated in memory or compiled to SQL by [zom-sql](#zom-sql).

## How zom differs from rom

rom is built on Ruby's runtime: classes register themselves, adapters
subclass base classes, and anything missing shows up as an exception when the
code runs. Zig has none of that, so zom does the same jobs at compile time.
Each row below says whether that part exists today or is planned (see
[plan.md](plan.md)).

| | rom (Ruby) | zom (Zig) |
|---|---|---|
| **Adapter registry** | `ROM.register_adapter(:csv, ROM::CSV)` puts the adapter in a global runtime table, and `ROM.container(:csv, path)` finds it there by symbol. | Zig has no runtime registry, and zom doesn't need one. An adapter is a Zig module that exports a `Gateway` type, and you pass that type in directly: `zom.Relation(Schema, zom_csv.Gateway)`. The contract is checked when the code compiles, not when it runs. `zom.Adapter` checks it, for `zom.memory` or any gateway you write. zom ships its adapters as modules of the zom package (`dep.module("zom_csv")`), not as separate packages; see [Writing an adapter](#writing-an-adapter). |
| **Adapter shape** | Adapters subclass `ROM::Gateway`, `ROM::Relation` and `ROM::Memory::Dataset`, then override methods. | No inheritance. A gateway is any type with the right declarations (see [the adapter contract](#the-adapter-contract)). File adapters *wrap* the memory engine, `zom.memory.Store(S)`, instead of subclassing it. |
| **Optional features** | Whether an adapter supports a command is found out at runtime, when the command is built or run. | An adapter simply leaves out `insert`, `update` or `delete`, and `relation.create(...).commit()` fails to compile with a message naming the adapter. `zom.Adapter(G).capabilities(S)` says what it supports. |
| **Checking an adapter** | `ROM::Lint` specs, run by each adapter gem. | `zom.lint.run(Gateway, Factory)`, a test suite each adapter runs in its own `zig build test`. *Today: read, filter, null, ordering, limit/offset, `one`, projection, insert, `insertMany`, update and delete checks.* |
| **Container** | `ROM.container` builds a runtime registry: `container.relations[:users]`. | Relations are types, so a container is a comptime struct with one field per relation: `app.relations.users`. A missing relation is a compile error, not a runtime lookup failure. *Today: `zom.Container`.* |
| **Schema inference** | rom-sql can read a table's columns from the database at boot. | A Zig struct has to exist when the code compiles, before any database is reachable, so you write the schema struct yourself, or generate it ahead of time from a live database with zom-pg's `zig build infer` step, and check it at startup with `Gateway.verify`. |
| **Structs** | `ROM::Struct` builds result classes at runtime from the schema. | You declare the entity struct (or use the tuple), and `mapTo` copies fields by name. `select(.{ .id, .name })` reads into a narrower struct built at compile time with `@Struct`, so reading a field that wasn't selected is a compile error. |
| **Type errors** | Found at runtime, if the database or a type check catches them. | Found at compile time: wrong field names, wrong value types, `null` on a non-optional field, an enum value that doesn't exist, an integer literal that doesn't fit. |
| **Errors** | Exceptions. | Error sets: `error.DuplicatePrimaryKey`, `error.ValueOutOfRange`, `error.MoreThanOneTuple`, returned with `try`. |
| **Memory** | Garbage collected. | Every call that returns a slice takes an allocator, and the caller frees the slice (see [Memory rules](#memory-rules)). |
| **Transformations** | Changeset `map { ... }` takes a block, which can capture variables. | `map` takes a comptime function, `fn (Tuple) Tuple`. Zig has no closures, so anything it needs has to be in the tuple. |
| **Limits** | Queries grow as needed. | Filters and changes are capped at 16 each, with asserts, so building a query never allocates. |

## Usage

### Quick start, in memory

The memory gateway needs no setup, so this runs anywhere, tests included:

```zig
const zom = @import("zom");

const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const PostSchema = zom.Schema(Post, "posts", .id, .{});
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = .{ .posts = zom.hasMany(PostSchema, .user_id) },
});
const Users = zom.Relation(UserSchema, zom.memory.Gateway);

var gw = zom.memory.Gateway.init(allocator, .{});
defer gw.deinit();
const users = try Users.init(&gw);

_ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();

const active = try users.where(.deleted_at, .eq, null).order(.name, .asc).toSlice(allocator);
defer allocator.free(active);
```

Run the tests with `zig build test`. Every code block in this README is also
compiled and run by that command, from [examples/readme.zig](examples/readme.zig),
except the Postgres example below, which is
[examples/pg_repo](examples/pg_repo/src/main.zig) and runs in zom-pg's CI
against a Postgres container.

### A repository and a transaction, on Postgres

[examples/pg_repo](examples/pg_repo/src/main.zig) is a small application:
a container with one [zom-pg](#zom-pg) gateway, a repository with a custom
view, and a sign-up that writes a user and their first posts in one
transaction, so a failure part way through leaves neither. Start Postgres,
create the tables, and run it:

```sh
docker run --rm -d --name zom-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:17
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres

cd examples/pg_repo
psql "$DATABASE_URL" -f schema.sql   # or: docker exec -i zom-pg psql -U postgres < schema.sql
zig build run                        # or: zig build run -- postgres://...
```

```text
committed: Achieng, with 2 posts
rolled back: DuplicatePrimaryKey (posts_pkey)
  users named Baraka: 0, posts by user 2: 0
active users: 1 of 2
Achieng <achieng@example.com>
  - Relations are values
  - Transactions roll back
```

The app depends on zom with `.pg = true`, which builds the `zom_pg` module
(see [its build.zig](examples/pg_repo/build.zig)). The schemas and the
container are the same as with any other gateway; only the gateway type
says Postgres:

```zig
const App = zom.Container(.{
    .gateways = .{ .db = zom_pg.Gateway },
    .relations = .{
        .users = .{ UserSchema, .db },
        .posts = .{ PostSchema, .db },
    },
});

/// The custom view: rom's `def active = where(deleted_at: nil)`.
const Users = struct {
    rel: @FieldType(App.Relations, "users"),

    pub fn active(self: Users) @TypeOf(self.rel) {
        return self.rel.where(.deleted_at, .eq, null);
    }
};

const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users, .posts = .plain } });
```

`main` reads the URL from its first argument or from `DATABASE_URL`, opens
the container, and checks both tables against the structs with zom-pg's
`verify`, so a missing `schema.sql` is one clear error at startup rather
than a failed query later:

```zig
var app: App = undefined;
try app.init(init.gpa, .{ .db = .{ .io = io, .url = url, .pool_size = 2 } });
defer app.deinit();

try verify(&app.gateways.db, UserSchema, arena);
try verify(&app.gateways.db, PostSchema, arena);
var repo = UserRepo.init(&app);
```

The sign-up runs in `app.transaction(.db, ctx, f)`. Zig has no closures, so
what `f` needs comes in as `ctx`, and `f` gets `tx`, the container's
relations rebound to the transaction's connection.
`UserRepo.fromRelations(tx)` builds the same repository over them. `f`
commits by returning and rolls back by returning an error:

```zig
const SignUp = struct {
    allocator: std.mem.Allocator,
    user: User,
    posts: []const Post,
};

fn signUp(s: SignUp, tx: App.Relations) !usize {
    const repo = UserRepo.fromRelations(tx);
    // zom-pg's strings belong to the caller, so a create that returns the
    // stored row takes an allocator (`commit()` would be a compile error).
    _ = try repo.create(s.user).commitAlloc(s.allocator);
    return repo.relations.posts.createMany(s.posts).commit();
}
```

The second sign-up fails on purpose: its post reuses id 10, which is
Achieng's. The user row is already written by then, and the rollback takes
it out again. The error comes back from `transaction` unchanged, and
`lastError()` has the Postgres details:

```zig
if (app.transaction(.db, SignUp{
    .allocator = arena,
    .user = .{ .id = 2, .name = "Baraka", .email = "baraka@example.com" },
    .posts = &.{.{ .id = 10, .user_id = 2, .title = "First!" }},
}, signUp)) |_| {
    return error.ExpectedRollback;
} else |err| switch (err) {
    error.DuplicatePrimaryKey => {
        const constraint = if (zom_pg.Gateway.lastError()) |e| e.constraint orelse "?" else "?";
        try out.print("rolled back: {t} ({s})\n", .{ err, constraint });
    },
    else => return err,
}
```

Then reads go through the view and the root shortcuts, and `combine` loads
the active users' posts with one `IN (...)` query:

```zig
try out.print("active users: {d} of {d}\n", .{ try repo.root().active().count(), try repo.all().count() });
const authors = try repo.root().active().order(.id, .asc)
    .combine(.posts, repo.relations.posts.order(.id, .asc))
    .mapTo(Author, arena);
```

Every row is read into `init.arena`, which `main` frees once on return:
zom-pg copies each string it returns into the allocator you pass (see
[Memory rules](#memory-rules)), and an arena is the simplest owner for a
short program. The example empties both tables when it starts, so every run
prints the same thing.

### Debugging: error return traces

When `main` returns an error, a Debug or ReleaseSafe build prints the error
and its **error return trace**: every `try` the error passed through on its
way out, innermost first. Run the example before applying `schema.sql`:

```text
$ zig build run
error: table 'users' doesn't match the schema; did you run `psql "$DATABASE_URL" -f schema.sql`?
users: no such table
error: SchemaMismatch
adapters/pg/src/verify.zig:116:5: 0x1230d63 in verify__anon_37199 (root.zig)
    return error.SchemaMismatch;
    ^
adapters/pg/src/gateway.zig:158:9: 0x1230f59 in verify__anon_37187 (root.zig)
        return verify_mod.verify(self, S, diagnostics);
        ^
examples/pg_repo/src/main.zig:159:13: 0x123111f in verify__anon_37156 (main.zig)
            return err;
            ^
examples/pg_repo/src/main.zig:89:5: 0x124934b in main (main.zig)
    try verify(&app.gateways.db, UserSchema, arena);
    ^
```

This is not a stack trace from where the program stopped: it records where
the error was returned and each place that passed it on, so it points into
zom-pg and pg.zig as well as your code. A wrong password or a stopped server
gives `ConnectionFailed`, with a trace down to the socket `connect` in
pg.zig. Some tips:

- The trace is only kept in Debug and ReleaseSafe builds. `zig build run
  -Doptimize=ReleaseFast` prints just `error: SchemaMismatch`.
- `catch |err| switch (err)` is where you decide which errors are expected
  (here `error.DuplicatePrimaryKey`) and pass the others on with
  `else => return err`, which keeps the trace going.
- zom-pg logs each Postgres error, with its SQLSTATE and message, at debug
  level under the `.zom_pg` scope. The example turns that scope down to
  `.info` in `std_options`, since it causes a duplicate key on purpose; set
  it back to `.debug` to see every one.
- `zom_pg.Gateway.lastError()` returns the last Postgres error on the
  current thread (code, message, detail, constraint), after the call that
  failed.

### A longer tour

Continuing from the quick start:

```zig
const Author = struct { id: u32, full_name: []const u8, posts: []const Post = &.{} };
const Posts = zom.Relation(PostSchema, zom.memory.Gateway);
const AuthorMapper = zom.Mapper(User, Author, .{
    .renames = &.{.{ .from = "name", .to = "full_name" }},
});

const posts = try Posts.init(&gw);
_ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values" }).commit();

// Updates and deletes target whatever the relation selects.
const changed = try users.byPk(1).update().set(.age, 32).commit(); // 1
const removed = try users.where(.age, .gt, 100).delete(); // 0

// Tuples become entities, each with its posts attached: one query for
// the users, one for their posts. One deinit frees the whole tree.
var authors = try users.combine(.posts, posts).mapWith(AuthorMapper, allocator);
defer authors.deinit();
```

## API (v0.2)

This is the public API as of 0.2.0: everything `src/root.zig` exports.
Adapters written from Phase 1 on build against it. While zom is on `0.x`, a
breaking change needs a minor version bump and an entry in
[CHANGELOG.md](CHANGELOG.md). The changes already planned are listed under
[Planned changes](#planned-changes).

### Exports

| Declaration | What it is |
|---|---|
| `zom.Schema(T, name, pk, options)` | Returns a schema type with `Tuple = T`, `name` (the dataset name), `primary_key` (a field of `T`, as an enum literal) and its associations. `pk` may be `null` for a view with no single unique field (see [Views](#views-schemas-without-a-primary-key)): `has_primary_key` is then false. `options` is `.{}`, or has `.associations` (see [Associations](#associations)) and `.plugins` (see [Plugins](#plugins)). |
| `zom.hasMany(Target, .fk)`, `zom.belongsTo(Target, .fk)` | Declare an association on a schema. `S.association(.name)` and `S.associations.name` return a `zom.Association`: `name`, `kind` (`zom.AssociationKind`: `has_many`, `belongs_to` or `custom`), `source`, `target`, `foreign_key` and `primary_key` (field names as strings), `cardinality` (`zom.Cardinality`: `.many` or `.one`) and `tag`, plus `Child()`, `Parent()` and `Key()` (the key type a combine groups by). |
| `zom.customAssociation(Target, .tag, .many)` | Declare an association with no foreign key zom can use, whose rows `Target`'s dataset finds itself through `loadAssociation`. `.one` instead of `.many` for an optional. See [Custom associations](#custom-associations-and-loadassociation). |
| `zom.Relation(S, Gateway)` | Returns an immutable relation type over schema `S` and an adapter's `Gateway`. Checks the [adapter contract](#the-adapter-contract) at compile time through `zom.Adapter(Gateway)`, which it exposes as `Relation.Adapter`. |
| `zom.RelationOf(S, Gateway, Output)` | The strict relation type whose reads return `Output`. `Relation(S, G)` is `RelationOf(S, G, S.Tuple)`, and `select` returns `RelationOf(S, G, Project(S.Tuple, fields))`. Exposes `Tuple`, `Output`, `projected` and `mode`. |
| `zom.RelationWith(S, Gateway, Output, mode)` | The relation type with every parameter. `RelationOf(S, G, Out)` is `RelationWith(S, G, Out, .strict)`, and `allowFallback()` returns `RelationWith(S, G, Out, .fallback)`. |
| `zom.Mode` | `strict` or `fallback`: what a relation does with query features its dataset does not support. See [Query support](#query-support-strict-and-fallback). |
| `zom.Scan`, `zom.ScanHook` | What a `.fallback` read that ran in memory reports (`adapter`, `relation`, `rows_fetched`, `rows_returned`), and the `*const fn (Scan) void` it reports to. |
| `zom.Project(T, .{ fields })` | The struct `select` reads into: only `fields` of `T`, in the order given, with their types and defaults. An empty tuple, an unknown field or a repeated one is a compile error. Equal arguments return the same type. |
| `zom.Adapter(G)` | Checks gateway `G` against the [adapter contract](#the-adapter-contract), reporting every problem in one compile error. Has `Gateway`, `name` (`G.adapter_name`), `Dataset(S)` (checks the dataset for schema `S`), `capabilities(S) Capabilities`, `has(S, cap) bool`, `readOnly(S) bool`, `require(S, cap, method)`, `supports(S) Supports`, and `filterGap(S, field, op)` / `orderGap(S, field)`, which return null when the dataset can evaluate that filter or sort key, else why not. |
| `zom.Supports` | The query features a dataset evaluates itself: `or` (boolean groups), `in` (`in`, `not_in`), `like` (`like`, `ilike`), `order_on` (order by any attribute, not only the key), `offset`, `projection`, `join` (`relation.join`), `per_group_limit` (`read` and `readProjected` page each group of `query.per_group`, and `loadAssociation` each key's slice, so `combine` pushes a target's per-parent page down; checked by `zom.lint`). `Supports.all` sets them all. |
| `zom.Join`, `zom.JoinFilter` | What `relation.join(.assoc)` stores in `query.join`: the association's name, the joined table, the key column on each side and its joined filters, each by column name: up to `Join.max_filters = 8` filters in `Join.max_nodes = 16` nodes, as the same flat tree a `Query` uses (`zom.query.FilterNode`; read it from `topNodes()`, or through `filterSlice()` when `isConjunction()`). Plain data, so a query is still copied by value without allocating; `join.targetQuery(C)` gives the filters back, groups and all, as a `zom.Query(C)`. Only an adapter with `supports.join` reads it. |
| `zom.Capability` | `writable`, `batch_insert`, `updatable`, `deletable`, `transaction`. |
| `zom.StringOwnership` | `dataset` or `caller`: who frees the strings in the tuples a dataset returns. See [Memory rules](#memory-rules). |
| `zom.strings` | Helpers for caller-owned strings: `freeFields(T, allocator, item, keep)` frees an item's string attributes except those named in `keep`, `freeAll(T, allocator, items)` frees every item's strings and the slice, and `dupeFields(T, allocator, item)` copies them (freeing its copies on error). |
| `zom.Capabilities` | A struct with one `bool` per `Capability`, all `false` by default. |
| `zom.adapter` | The module behind `Adapter`, `Capability` and `Capabilities`. |
| `zom.Query(T)` | The adapter-neutral query a relation builds: a filter tree, sort keys (`orders`, at most `max_orders = 4`, read through `orderSlice()`, most significant first), `limit: ?usize`, `offset: usize`, `per_group: ?Field` (set by `combine` on a dataset with `supports.per_group_limit`: the limit and offset then page each group of rows sharing that attribute's value, nulls as one group; `pageGroups(rows, scratch)` applies the page to rows in memory, per group or not), and `all: bool` (default false: set it to say an update or delete with no filters is meant to touch every row, which [zom-sql](#zom-sql) otherwise refuses; it changes nothing about which rows match). The tree is stored flat so a copy is a full copy: `filters` (at most `max_filters = 16`) and `nodes` (at most `max_nodes = 32`: filters plus `any` / `all` / `not` groups, which refer to children by index), AND-ed at the top level. An adapter without `or` support reads an AND-only query through `filterSlice()` (it asserts `isConjunction()`); one with it walks `nodeSlice()` from `topNodes()`. `matches(row)` and `truth(row) ?bool` evaluate the query in memory with SQL's three-valued logic, alongside `lessThan(orders, a, b)` (the comparator for `std.mem.sort(T, rows, query.orderSlice(), lessThan)`: key by key, the next key breaking ties), `orderBy(order, a, b)` (one key) and `fieldValue(row, field)`. Nested types: `Field` (enum of `T`'s fields), `Filter` (`field`, `op`, `operand`), `Node` (`filter`, `and_group`, `or_group`, `not`), `Children`, `Order`, `Change`. `max_in = 64` bounds one `in` list. The query also builds itself, with the same `where` / `whereIn` / `whereNotIn` / `whereAny` / `whereNot` / `order` / `reorder` as a relation (and `addOrder`), so adapters and tests can make one without a gateway. |
| `zom.any(conds)`, `zom.all(conds)`, `zom.not(cond)` | Boolean groups to nest inside `whereAny` / `whereNot`. A condition is `.{ field, op, value }` or another group. |
| `zom.Value` | The runtime value carried by filters and changes. See [Value](#value). |
| `zom.Op` | Filter operators: `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `in`, `not_in`, `like`, `ilike`, `between`, `is_null`, `is_not_null`. `op.operand()` returns the `Operand` variant it takes. |
| `zom.Direction` | `asc`, `desc`. |
| `zom.Container(spec)` | Declares gateways and relations once; `init(self, allocator, Config)` / `deinit()` connect and disconnect them all. See [Container](#container). |
| `zom.Repository(App, .{ .root, .relations })` | Groups some of a container's relations around a root relation: `init(&app)`, `relations` (one field per relation, or its wrapper struct), `root()`, and the root shortcuts `byPk`, `where`, `all`, `create`, `createMany`, `update`, `delete`. See [Repository](#repository). |
| `zom.plugins` | Schema plugins: `timestamps(.{ .created, .updated, .unit })`, the `Context` and `Clock` hooks read, `ChangeList(T)` (what `beforeUpdate` hooks edit) and `max_changes`. See [Plugins](#plugins). |
| `zom.changeset` | `Create(Rel)`, `CreateMany(Rel)`, `Update(Rel)` and `Scoped(Rel, keys)`, the types returned by `relation.create`, `relation.createMany`, `relation.update` and `relation.associate`. You don't name them yourself; `Scoped`'s `Input` is the struct its `create` takes. |
| `zom.Mapper(Src, Dst, .{ .renames })` | A comptime mapper: `call(src) Dst` and `many(allocator, srcs) ![]Dst`. A `Dst` field takes the `Src` field of the same name (or its rename), else its default; neither is a compile error. Every field is set. `sources` lists the `Src` fields it copies, and `options` the options it was made with. |
| `zom.Combined(Source, association, Target)`, `zom.CombineResult(E)` | What `relation.combine(.assoc, target)` returns, and what its `mapTo` / `mapWith` return: `items: []E` and the arena owning them, freed with `deinit()`. See [Associations](#associations). |
| `zom.combineMany(.{ .into, .parent_key, .child_key }, allocator, parents, children)` | **Deprecated:** use `relation.combine`. Sets `parent.into` to the children whose `child_key` equals the parent's `parent_key`, on slices already loaded, in O(n·m). Build with `-Dno-deprecated` to make each call a compile error. |
| `zom.mapper` | The module behind `Mapper` and `combineMany`, with their option types `Options`, `Rename` and `CombineOptions`, and `isMapper(M)`, true when `M` was made by `zom.Mapper`. |
| `zom.codec` | Text cells to field values, for adapters whose rows arrive as strings. `decodeField(F, text, opts) !F` decodes one cell, and `decodeRow(T, cells, opts, ?*Diagnostic) !T` decodes a row, in field order or through `Options.columns`. `Options.null_text` (default `""`) means null. Strings borrow the cells. On error the `Diagnostic` has `row`, `column`, `field`, `text` and `err`, and formats with `{f}` as `14:3 (age): "abc" is not an integer from 0 to 255`. The other way, `encodeField(writer, value, opts)` and `encodeRow(writer, T, row, opts, sep)` write values back so they decode to the same thing: ints `{d}`, floats in their shortest round-trip form (decimal, or scientific outside `1e-6`..`1e21`), `true`/`false`, tag names, strings as they are, `null` as `null_text`. Nothing is quoted; that is the format writer's job. The accepted spellings are listed in `src/codec.zig`. |
| `zom.memory` | The in-memory adapter: `Gateway` (`adapter_name = "memory"`, `Config = struct {}`, `init(allocator, Config)`, `deinit()`), whose dataset is `Store(S)`. Every capability; its `transaction` saves each store's rows and puts them back on error, for tests without a database. |
| `zom.memory.Store(S)` | The in-memory row engine, usable without a gateway: `init(allocator)`, `deinit()`, `read`, `count`, `insert`, `insertMany`, `update`, `delete`, plus `rows() []const Tuple` (every row, in insertion order), `load(row)` and `loadMany(rows)` (insert without the primary-key check, for trusted bulk loads) and `clear()`. Strings are copied into the store's arena; rows it returns point into it until `clear` or `deinit`. |
| `zom.lint` | The adapter conformance suite, see [Checking an adapter](#checking-an-adapter-with-zomlint). Also exports the schema it tests on, `Users` (`User`, `Role`), its seed rows, `users`, `OnDuplicate` and `expectSharedError`. |
| `zom.query` | The module behind `Query`, `Value`, `Op` and `Direction`, plus `Operand` (a filter's value side: `none`, `one`, `many: ValueList` or `range: [2]Value`), `ValueList` (a borrowed list read with `at(i)`) and `like(text, pattern, case)`, the `LIKE` matcher `matches` uses. Adapters can use `toValue(x) Value` and `fromValue(F, value) !F` to convert between attribute values and `Value`. Its `assert*`, `isString` and `isComptimeOnly` helpers are used by the core and are not part of the frozen API. |

### Relation

`users` below is a `zom.Relation(S, Gateway)`. Building methods return a new
relation and never touch the dataset. `field` is always an enum literal, and
`value` is type-checked against the attribute at compile time.

| Method | Returns | Notes |
|---|---|---|
| `Relation.init(*Gateway)` | `!Relation` | Asks the gateway for the schema's dataset. |
| `where(field, op, value)` | `Relation` | Filters are AND-ed. `op` is comptime, and decides what `value` is (below). `eq null` / `neq null` are aliases of `is_null` / `is_not_null`. |
| `whereIn(field, slice)`, `whereNotIn(field, slice)` | `Relation` | `in` / `not_in` over a runtime slice (or pointer to an array) of the attribute's type, at most `max_in` long. Borrowed, not copied. |
| `whereAny(.{ cond, ... })` | `Relation` | AND-s the conditions OR-ed together: `whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })`. A condition is `.{ field, op, value }`, checked like `where` (a runtime slice works for `in`), or a nested `zom.any`, `zom.all` or `zom.not`. A condition too big for `max_filters` / `max_nodes` is a compile error; running out of room at runtime panics. |
| `whereNot(cond)` | `Relation` | AND-s NOT `cond`. SQL's three-valued logic: where `cond` is unknown (`NULL > 30`), so is its negation, and the row matches neither. |
| `byPk(value)` | `Relation` | `where(primary_key, .eq, value)`. A compile error on a view (no primary key). |
| `order(field, direction)` | `Relation` | Adds a sort key after those already set: `.order(.role, .asc).order(.age, .desc)` is `ORDER BY role ASC, age DESC`. At most `Query.max_orders = 4` keys; a fifth panics. |
| `reorder(.{ .{ field, direction }, ... })` | `Relation` | Replaces every sort key; `reorder(.{})` removes the order. More than `max_orders` keys is a compile error. |
| `limit(n)`, `offset(n)` | `Relation` | `n: usize`. |
| `page(n).perPage(k)` | `zom.pagination.Page(Relation)` | Page `n` (from 1) of `k` rows: `offset((n - 1) * k).limit(k)`. Its `toSlice(allocator)` reads the rows, and `paginate(allocator)` the rows with the total. See [Pagination](#pagination). |
| `select(.{ field, ... })` | a projected relation | Reads return `zom.Project(Tuple, fields)` instead of `Tuple`. See [Projections](#projections). |
| `allowFallback()` | a `.fallback` relation | Query features the dataset does not support compile, and run in memory. See [Query support](#query-support-strict-and-fallback). |
| `onScan(hook)` | `Relation` | The same relation, reporting in-memory reads to `hook` (a `zom.ScanHook`, or null). A `Container` sets it for you. |
| `toSlice(allocator)` | `![]Output` | Caller frees, with `free(allocator, rows)` to work on any adapter (see [Memory rules](#memory-rules)). `Output` is `Tuple`, or the projected struct after `select`. |
| `one(allocator)` | `!?Output` | `null` when empty, `error.MoreThanOneTuple` when ambiguous. Free the tuple with `freeOne(allocator, tuple)`. |
| `first(allocator)` | `!?Output` | Free like `one`. |
| `free(allocator, rows)` | `void` | Frees what `toSlice` returned: the slice, and its strings when the adapter's strings are caller-owned. |
| `freeOne(allocator, tuple)` | `void` | Frees a tuple's strings when they are caller-owned; a no-op on `.dataset` adapters. |
| `count()` | `!usize` | The number of rows `toSlice` would return, so `limit` and `offset` apply. On a `.fallback` relation it is `count(allocator)`, because it may have to read the rows to count them. |
| `mapTo(E, allocator)` | `![]E` | `mapWith(zom.Mapper(Output, E, .{}))`. |
| `mapWith(M, allocator)` | `![]M.Output` | `M` is a `zom.Mapper` whose `Input` is `Output`. |
| `combine(.assoc, target)` | `zom.Combined(...)` | This relation with association `assoc` of its schema, read from `target`, a relation over the association's target schema, or a combine of one for nested levels. Lazy; its `mapTo(E, allocator)` and `mapWith(M, allocator)` return a `zom.CombineResult(E)`. See [Associations](#associations). |
| `join(.assoc)` | `Relation` | The rows that have at least one row of association `assoc`, each once, as the same relation type. Needs `supports.join` (a compile error otherwise, even on a `.fallback` relation). See [Join](#join). |
| `whereJoined(.assoc, field, op, value)` | `Relation` | A filter on the joined rows, typed like `where` on the target's tuple. Needs `join(.assoc)` first. |
| `whereJoinedIn(.assoc, field, values)`, `whereJoinedNotIn(...)` | `Relation` | `whereIn` / `whereNotIn` on the joined rows: a runtime slice, borrowed, at most `max_in` long. |
| `whereJoinedAny(.assoc, conds)`, `whereJoinedNot(.assoc, cond)` | `Relation` | `whereAny` / `whereNot` on the joined rows. Needs `supports.or` on the joined dataset. |
| `create(tuple)` | `Create` | `.map(f)` applies `f: fn (Tuple) Tuple`; `.associate(.assoc, parent)` overwrites the tuple's foreign key from `parent`; `.commit()` returns `!Tuple`, the stored tuple. `.commitAlloc(allocator)` does the same on every adapter, allocating the returned strings when they are caller-owned (zom-pg, where plain `commit()` is a compile error); free the result with `freeOne`. A compile error after `select`. |
| `createMany(tuples)` | `CreateMany` | A compile error after `select`. `tuples: []const Tuple`, borrowed until commit. `.commit()` returns `!usize`, the rows inserted. Uses the dataset's `insertMany`, else loops over `insert` (see [the adapter contract](#the-adapter-contract)). `.associate(.assoc, parent)` sets every tuple's foreign key on a copy, so the changeset then commits with `.commitAlloc(allocator)`. |
| `associate(.assoc, parent)` | `zom.changeset.Scoped(...)` | Sets the foreign key of `belongsTo` association `assoc` from `parent`, the target's tuple or a `select` of it that kept the key. Its `create(data)` and `createMany(rows)` take `Input`, the tuple without that key; chain `.associate` for more associations. Its `createMany` commits with `commitAlloc(allocator)`. A compile error after `select`. See [Associated creates](#associated-creates). |
| `update()` | `Update` | `.set(field, value)` adds a change (at most `max_changes = 16`); `.commit()` returns `!usize`, the rows changed. |
| `delete()` | `!usize` | The rows removed. |

On a `.fallback` relation, `update().commit()` and `delete()` return
`error.UnsupportedFilter` when the dataset can't evaluate every filter:
writes never run in memory. Joined writes use the same semi-join selection
as joined reads.

What `where` takes for each op. Every value is type-checked against the
attribute, and a comptime value (`.c`, `300`) must fit it.

| `op` | `value` | Example |
|---|---|---|
| `eq`, `neq`, `lt`, `lte`, `gt`, `gte` | a value, or `null` on an optional attribute | `where(.age, .gte, 18)` |
| `in`, `not_in` | a tuple of comptime-known values, at most `max_in` (64) | `where(.id, .in, .{ 1, 2, 3 })` |
| `like`, `ilike` | a string pattern, on string attributes only | `where(.name, .like, "Ach%")` |
| `between` | `.{ lo, hi }`, both inclusive | `where(.age, .between, .{ 18, 30 })` |
| `is_null`, `is_not_null` | `{}`, on an optional attribute | `where(.deleted_at, .is_null, {})` |

Nulls follow SQL: a null attribute only matches `is_null` / `is_not_null`.
`NULL IN (...)`, `NULL NOT IN (...)` and `NULL LIKE ...` never match, a null
inside an `in` list equals nothing and makes `not_in` match nothing, and an
empty `in` list matches nothing. In a `like` pattern, `%` matches any run of
characters, `_` one UTF-8 character, and `\` escapes the next one (`\%`,
`\_`, `\\`); `ilike` folds ASCII case only. Building a query never
allocates: a tuple's values become a static array, and `whereIn` borrows the
slice.

The relation's fields `dataset` and `query` are public too, so a relation
can be handed to an adapter function such as `zom_sql.compileRelation`.

#### Projections

`select` narrows what a relation reads, like `SELECT id, name`. The query
stays typed on the full tuple, so `where` and `order`, before or after
`select`, may still use attributes that were not selected:

```zig
const names = try users.where(.age, .gt, 18).order(.age, .desc).select(.{ .id, .name }).toSlice(allocator);
defer allocator.free(names);
// @TypeOf(names[0]) has exactly `id` and `name`; `names[0].age` does not compile.
```

- Fields are listed as enum literals and come out in that order, with the
  types and defaults they have in the tuple. An empty list, an unknown field
  or a field listed twice is a compile error.
- **The primary key does not have to be selected.** rom doesn't require it,
  `SELECT name FROM users` is valid SQL, and zom never needs the key of a
  projected row: `update()` and `delete()` still work after `select`,
  because they go through the relation's query, not through rows read from
  it. `create` and `createMany` take whole tuples, so they are compile
  errors after `select`.
- `select` on a projected relation narrows it further, and may only name
  fields that were selected. Equal field lists give equal types, so
  `users.select(.{ .id, .name })` written twice is one type.
- A dataset with `supports.projection` reads the projection itself through
  `readProjected`. Any other dataset reads whole tuples, which zom maps down
  with `zom.Mapper` and frees, so `select` works with every adapter.

#### Pagination

`page(n).perPage(k)` is page `n` of `k` rows, counting from 1, and
`paginate` reads it along with the total:

```zig
const p = try users.order(.id, .asc).page(2).perPage(20).paginate(allocator);
defer p.free(allocator);
// p.rows: rows 21 to 40 (fewer on the last page, none past it)
// p.total: every row of `users`, p.pages: ceil(total / 20)
// p.page == 2, p.per_page == 20
```

- The page's query is `offset((n - 1) * k).limit(k)`, replacing any
  `limit` and `offset` set before. `total` is `count()` on the same query
  without them, so filters count and paging doesn't. A page past the end
  has no rows and the same total.
- `page(0)` or `perPage(0)` is a compile error with a literal, and a panic
  with a runtime value: check user input first. When `(n - 1) * k` does
  not fit in `usize`, the read returns `error.ValueOutOfRange`.
- `paginate` is two dataset calls, a count then a read; run it in a
  transaction if a write in between would matter. `toSlice(allocator)`
  reads the rows alone, and `paged()` returns the relation with the
  offset and limit applied.
- Every relation has it, including projected and `.fallback` ones, and it
  needs `supports.offset` like `offset` does. It is a relation method,
  not a schema plugin: plugins hook into changesets, and paging only
  composes `limit`, `offset` and `count`.

#### Query support: strict and fallback

A dataset says which query features it evaluates with `supports` and,
optionally, per attribute with `filterable` and `orderable` (see [the
adapter contract](#the-adapter-contract)). A relation is `.strict` by default:
building a query the dataset can't run is a compile error, at the call that
needs the missing feature, naming the adapter, the relation, the call and the
feature:

```
zom: adapter 'limited' cannot evaluate `where(.name, .eq, ...)` on relation 'items': its dataset's `filterable` rejects `.eq` on 'name'; call `allowFallback()` on the relation to evaluate it in memory instead
```

`where`, `whereIn`, `whereNotIn` and `whereAny` / `whereNot` (every
condition inside them too) check filters, `order` and `reorder` check sort
keys, and `offset` and `page` check `supports.offset`. `select` and `limit` work on
every dataset.

`users.allowFallback()` returns the same relation in `.fallback` mode, where
those calls compile. Each read then splits the query: the top-level
conditions the dataset supports go to `read`, and zom filters the rows it
returns with the rest, through `Query.matches`. Once anything runs in
memory, the sort (when the dataset can't do it), `offset` and `limit` run in
memory too, after the filter, so pages are never short; `count` follows the
same rule.

**The cost is a hidden full scan.** A read whose filter or sort runs in
memory fetches every row that matches the supported part, with no limit,
however small the page. (When only `offset` is unsupported, the dataset reads
the first `offset + limit` rows instead.) So fallback is opt-in per relation,
which leaves a visible `allowFallback()` wherever a scan can happen, and
every such read calls the relation's scan hook with `zom.Scan{ adapter,
relation, rows_fetched, rows_returned }`. Set it once with the container's
`.on_scan`, or with `relation.onScan(hook)`, then log it in an app or assert
on it in a test. A read the dataset evaluates entirely is not reported.

```zig
const young = try users.allowFallback().where(.age, .lt, 30).limit(10).toSlice(allocator);
defer allocator.free(young);
```

### Container

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
support](#query-support-strict-and-fallback)).

A relation that names a gateway the container doesn't have, a relation that
isn't `.{ Schema, .gateway }`, and a gateway that fails `zom.Adapter` are all
compile errors.

[examples/csv_users](examples/csv_users/src/main.zig) puts two adapters in
one container: users read from `data/users.csv` through `zom_csv.Gateway`,
posts held in `zom.memory.Gateway`, combined with `users.combine(.posts, posts)`. Run it
with `cd examples/csv_users && zig build run`; `zig build test` at the root
runs it too and checks its output.

### Repository

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
[examples/pg_repo](#a-repository-and-a-transaction-on-postgres) does this
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

### Plugins

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

#### Writing a plugin

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

#### Instrumentation

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

### Associations

A schema declares its associations once, in its options, so `combine`,
`join` and `associate` never take keys:

```zig
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
    },
});

const posts = UserSchema.association(.posts); // or UserSchema.associations.posts
// posts.kind == .has_many, posts.target == PostSchema,
// posts.foreign_key == "user_id", posts.primary_key == "id"
```

`hasMany(Target, .fk)` means `Target`'s rows hold `fk`, pointing at this
schema's primary key. `belongsTo(Target, .fk)` means this schema's rows hold
`fk`, pointing at `Target`'s primary key. These are checked when the schema
is compiled, whether or not anything uses the association yet: the foreign key
must be a field of the right tuple, and its type must be the key's type or
that type made optional (`?u32` for a `u32` id). `S.association(.postz)` is a
compile error that lists the schema's associations.

#### Views: schemas without a primary key

Some datasets have no single unique field: a row of TigerBeetle's balance
history is unique per account and timestamp, but one transfer's timestamp is
on both its accounts' rows. Declare such a schema with `null` as its key:

```zig
const BalanceSchema = zom.Schema(Balance, "balances", null, .{
    .associations = struct {
        pub const account = zom.belongsTo(AccountSchema, .account_id);
    },
});
```

`BalanceSchema.has_primary_key` is false, and whatever needs the key is a
compile error: `byPk`, `BalanceSchema.primary_key`, a `belongsTo` pointing at
the view, and a `hasMany` or custom association declared on it. A
`belongsTo` from the view and a `hasMany` into it work, since they use the
other schema's key. The memory store checks no keys for it (no
`error.DuplicatePrimaryKey`), and zom-pg's `verify` skips the primary-key
comparison.

**Why `struct { pub const ... }`.** Zig evaluates a function's arguments
before calling it, so with `.associations = .{ .posts = zom.hasMany(PostSchema, .user_id) }`
building `UserSchema` needs `PostSchema`, and if `PostSchema` names
`UserSchema` back, the compiler reports a dependency loop. A struct's
declarations are only evaluated when used, so the struct form lets both
schemas exist first and resolves the associations afterwards. The
anonymous-struct form `.{ .posts = ... }` is also accepted, for associations
that don't lead back to the schema declaring them.

#### Combine

`users.combine(.posts, posts)` loads the users with their posts, ROM's
`users.combine(:posts)`. The second argument is the relation to read the
posts from: any relation over the association's target schema, so it can
carry its own filters and order. With a container, pass its relation:
`app.relations.users.combine(.posts, app.relations.posts)`.

```zig
const Author = struct { id: u32, name: []const u8, posts: []const Post };

var result = try users.where(.age, .gt, 18).order(.id, .asc)
    .combine(.posts, posts.where(.published, .eq, true))
    .mapTo(Author, allocator);
defer result.deinit(); // frees every author, post and string
for (result.items) |author| std.debug.print("{s}: {d} posts\n", .{ author.name, author.posts.len });
```

Nothing is read until `mapTo` (or `mapWith(M, allocator)`, for a mapper
with renames). Then:

1. The users are read once, with their filters, order and limit.
2. Their distinct keys are collected, and the posts are read with
   `whereIn(.user_id, keys)`: one query, or ⌈keys / `Query.max_in`⌉ when
   there are more than 64 keys. Each post keeps its relation's order within
   its user.
3. The posts are grouped by key with a hash map, in O(users + posts), and
   each `Author.posts` gets its own: an empty slice when there are none.
   Posts whose user was filtered out are dropped.

`belongsTo` works the other way: `posts.combine(.author, users).mapTo(Byline, allocator)`
fills `Byline.author: ?User` (or any struct the user maps to), which is null
when the foreign key is null or its user was not read.

The entity needs a field named after the association: `[]const X` for
`hasMany`, `?X` for `belongsTo`, where `X` is the target's tuple or any
struct `zom.Mapper` can map it to. It needs no default. A missing field, a
field of the wrong shape, a target relation over the wrong schema and a key
dropped by `select` are compile errors.

Combine groups by the primary key's type (without `?`), with a hash map.
Supported key types are integers (signed up to `i64`, unsigned up to
`u128`, so TigerBeetle ids work), enums, `bool` and strings (`[]const u8`).
Any other key type is a `zom.combine` compile error naming it: floats,
because they compare badly as keys, and structs, arrays or other slices,
because composite keys aren't supported yet.

`mapWith(M, allocator)` takes a `zom.Mapper`, which combine rebuilds to
leave the association field alone, so it needs no default there either. It
also takes a mapper written by hand: a struct with `Input` (the source
relation's `Output`), `Output` and `pub fn call(Input) Output`. Combine
can't rebuild that one, so it is used as is: its `call` must set the
association field to something, such as `&.{}` or `null`, and combine then
overwrites it. A struct without that `call` is a compile error.

A `limit` or `offset` on the target relation pages each user's posts, not
the post query: `users.combine(.posts, posts.order(.id, .desc).limit(3))`
gives every user their latest three posts. A limit on the query itself
would apply to each batch of `max_in` keys and mean nothing. For a
`belongsTo`, the parent is the first row of its page, so `offset(1)` leaves
it null.

Where the page is applied depends on the target's dataset. One with
`supports.per_group_limit` pages each user's posts itself, so only the
posts kept are read: zom-pg (through zom-sql) numbers them with
`ROW_NUMBER() OVER (PARTITION BY "user_id" ORDER BY ...)` and sends back
those on the page, and zom-tigerbeetle asks the cluster for each account's
page alone. Any other dataset, or a `.fallback` target whose read filters,
sorts or skips in memory, gets the query without the page: zom reads every
matching post and keeps each user's first three in the relation's order.
The result is the same either way.

The result is a tree of allocations, so `mapTo` returns a
`zom.CombineResult(Author)`: `items`, plus an arena owning every slice and
string in it, including the strings of a caller-owned adapter like zom-pg.
One `deinit()` frees it all.

#### Custom associations and `loadAssociation`

Steps 2 and 3 assume each child row holds one foreign key. Some don't: a
TigerBeetle transfer belongs to an account as its `debit_account_id` *or*
its `credit_account_id`. `zom.customAssociation` declares such an
association by what the target's dataset calls it, and whether each source
row gets a slice (`.many`) or an optional (`.one`):

```zig
pub const Account = zom.Schema(tb.Account, "accounts", .id, .{
    .associations = struct {
        pub const transfers = zom.customAssociation(Transfer, .account_transfers, .many);
    },
});

var history = try accounts.byPk(id).combine(.transfers, transfers).mapTo(AccountWithTransfers, allocator);
```

The target's dataset then loads the rows itself, with an optional
declaration that `combine` looks for with `@hasDecl` at compile time:

```zig
pub fn loadAssociation(
    self: *Self,
    comptime a: zom.Association,
    keys: []const a.Key(),     // the source rows' distinct keys
    query: zom.Query(S.Tuple), // the combined relation's whole query
    allocator: std.mem.Allocator, // the result's arena
) ![]const []const S.Tuple    // one slice per key, in the order of `keys`
```

When a dataset declares it, *every* combine into that dataset calls it once
instead of steps 2 and 3, for `hasMany` and `belongsTo` too, so a backend
can pick a better request than an `in` query (zom-tigerbeetle uses
`get_account_transfers`). It must apply all of `query`, including filters a
`.fallback` relation would have run in memory, and order each slice by it;
a row may be in several slices. Its `limit` and `offset` are taken off and
applied to each slice afterwards, unless the dataset declares
`supports.per_group_limit`: then it gets them and pages each key's slice
itself. Everything it returns lives in the arena,
so it frees nothing. A custom association combined into a dataset without
`loadAssociation` is a compile error, and so are `join` and `associate` on
one, which need a foreign key.

#### Join

`users.join(.posts)` keeps the users that have at least one post, ROM's
`users.join(:posts)`. Where `combine` loads the posts alongside the users,
a join filters the users by their posts in the dataset and reads only the
users' own columns, so it returns a relation of the same type: `where`,
`order`, `limit`, `offset`, `count`, `select` and `combine` all still apply,
before or after it. `whereJoined` filters on the joined rows, typed and
checked like `where` on the posts' tuple:

```zig
// The users with at least one published post, each once.
const authors = try users.join(.posts)
    .whereJoined(.posts, .published, .eq, true)
    .order(.name, .asc)
    .toSlice(allocator);
defer users.free(allocator, authors);
```

Several `whereJoined` filters are AND-ed and must all hold for the same
post. A user with several matching posts still comes back once. `belongsTo`
joins the other way: `posts.join(.author).whereJoined(.author, .role, .eq,
.admin)` is the posts written by admins, and a post whose foreign key is
null has no author to join.

`whereJoinedAny` and `whereJoinedNot` take the same conditions as
`whereAny` and `whereNot`, over the joined tuple, and need `supports.or` on
the joined dataset. `whereJoinedIn` and `whereJoinedNotIn` take a runtime
slice and borrow it, like `whereIn`:

```zig
// The users with a post that is published or has 10+ likes.
const busy = users.join(.posts)
    .whereJoinedAny(.posts, .{ .{ .published, .eq, true }, .{ .likes, .gte, 10 } });
// The users with one of these posts.
const picked = users.join(.posts).whereJoinedIn(.posts, .id, post_ids);
```

Everything on a join is AND-ed for the same joined row, groups included.
So `whereJoinedNot(.posts, .{ .published, .eq, true })` is the users with
a post that is not published, not the users with no published post.

A join needs `supports.join`. Without it, `join` and `whereJoined` are
compile errors on a `.fallback` relation too, since a join reads another
dataset and can't run in memory on this one's rows. zom-pg and the memory
gateway support it; csv and yaml do not. On zom-sql it compiles to a
correlated semi-join

```sql
SELECT "users"."id", "users"."name", ... FROM "users"
WHERE EXISTS (SELECT 1 FROM "posts"
  WHERE "posts"."user_id" = "users"."id" AND "posts"."published" = $1)
ORDER BY "users"."name" ASC
```

with every column qualified by its table. Each user comes back once with
no `DISTINCT`, so columns without equality (`json`) and projections work
as on an unjoined query. The memory gateway runs a hash
semi-join: the matching posts' keys go into a set, and a user is kept when
its key is in it, in O(users + posts).

A query holds one join: joining the same association again changes
nothing, and joining a second one panics, as does `whereJoined` without
the `join`. `update` and `delete` on a joined relation affect each matching
source row once. The SQL compiler uses the same `EXISTS` subquery;
memory snapshots the matching rows before changing them.

#### Associated creates

`posts.associate(.author, user)` is ROM's `changeset.associate(user)`, with
the parent first: its `create` takes the post without `user_id`, and the
key comes from `user`:

```zig
const author = (try users.byPk(1).one(allocator)).?;
_ = try posts.associate(.author, author)
    .create(.{ .id = 12, .title = "Changesets" })
    .commit();
```

The struct `create` takes is the tuple without the association's foreign
key, with the same types and defaults otherwise, so the literal is typed
as usual and the key can't be forgotten or given twice. Chain `associate`
for several `belongsTo` associations (a comment's post and author). For a
batch, `posts.associate(.author, author).createMany(&rows)` takes rows of
that struct, `@TypeOf(scoped).Input`, and commits with
`commitAlloc(allocator)`, because it builds the stored tuples in a copy.

**Why the parent comes first.** ROM's `create(data)` leaves out `user_id`,
but a Zig struct has no unset fields, so a post literal without `user_id`
doesn't compile. Giving the key a default in the tuple would let a post
silently belong to user 0. Making `create` accept a partial struct would
mean an `anytype` parameter, and Zig 0.16 doesn't coerce an anonymous
struct to a named one, so every `create` literal would lose its result
type (`.id = @intCast(n)` would stop compiling). So `create` keeps taking a
whole tuple. ROM's order still works if you give the key a value first:
`posts.create(.{ .id = 13, .user_id = undefined, ... }).associate(.author, author)`,
and `posts.createMany(&tuples).associate(.author, author).commitAlloc(allocator)`
for a batch. Nothing catches a forgotten `associate` in that form.

The parent must be the target's tuple, or a `select` of it that kept the
key (any struct whose fields are all fields of the target's tuple, with
the same types). Any other type, such as another schema's tuple, is a
compile error, and so is a `hasMany` association, whose foreign key is in
the other schema's rows: `users.associate(.posts, post)` points you at
`posts.associate(.author, ...)`.

#### Nesting

The relation passed to `combine` can be a combine itself, so a combine
loads more than one level: users with their posts, each post with its
comments.

```zig
const Comment = struct { id: u32, body: []const u8 };
const PostWithComments = struct { id: u32, title: []const u8, comments: []const Comment };
const Author = struct { id: u32, name: []const u8, posts: []const PostWithComments };

var result = try users.order(.id, .asc)
    .combine(.posts, posts.order(.id, .asc).combine(.comments, comments.order(.id, .asc)))
    .mapTo(Author, allocator);
defer result.deinit(); // frees every level
```

The element type of `Author.posts`, here `PostWithComments`, drives the
inner level: each post row is mapped to it by attribute name, and its
`comments` field is filled the way `Author.posts` is. The field-shape
checks (`[]const X` for `hasMany`, `?X` for `belongsTo`) and the
per-parent paging apply at every level, and levels can be
nested deeper the same way. `hasMany` and `belongsTo` mix freely:
`posts.combine(.author, users)` inside a combine fills each post's `?User`.

Each level runs once, on every row the level above it read:

1. The users are read.
2. The posts are read with `whereIn(.user_id, ...)`, ⌈users / `max_in`⌉
   queries.
3. The comments are read with `whereIn(.post_id, ...)`, ⌈posts / `max_in`⌉
   queries, over all posts at once, not per batch of the level above.

So a combine makes 1 + Σ ⌈keys / `max_in`⌉ queries across its levels, and a
level whose parents have no keys makes none. A level into a dataset with
`loadAssociation` loads through it, and the rows it returns get their own
association filled the same way. One `result.deinit()` frees the whole
tree. The inner levels map by attribute name; `mapWith` applies to the
outermost rows only.

The `whereIn` takes one of the target query's `max_filters` filters (and
`max_nodes` nodes), so a target relation that already uses them all is
`error.CombineTargetFull`, at any level, even when there are no keys. A
target dataset with `loadAssociation` adds no filter and has no such limit.

### Value

```zig
const big: zom.Value = .{ .uint = std.math.maxInt(u64) };
std.debug.assert(big.order(.{ .int = -1 }).? == .gt);
std.debug.assert(big.order(.{ .string = "x" }) == null); // different kinds never compare
std.debug.assert(zom.query.toValue(@as(u64, 7)).eql(.{ .int = 7 }));
const id: zom.Value = .{ .uint128 = std.math.maxInt(u128) }; // a TigerBeetle id
std.debug.assert(id.order(big).? == .gt);
```

`zom.Value` is a `union(enum)`:

| Variant | Holds |
|---|---|
| `null` | A `null` optional attribute. |
| `boolean: bool` | `bool`. |
| `int: i64` | Every integer type up to 64 bits, except `u64`. |
| `uint: u64` | `u64` (and `usize` on 64-bit targets), and integer literals above `maxInt(i64)`. |
| `uint128: u128` | Unsigned integers of 65 to 128 bits (`u128` ids and amounts), and integer literals above `maxInt(u64)`. |
| `float: f64` | Float types. |
| `string: []const u8` | Strings, and enum values (by tag name). |

`a.order(b)` returns `?std.math.Order`: numbers compare across `int`,
`uint`, `uint128` and `float` (integers exactly, by widening both sides to
`i129`; against a float, through `f64`), strings compare bytewise, and
values of different kinds return `null`. `a.eql(b)` is `order == .eq`.
Signed integers wider than 64 bits, and any integer wider than 128, are a
compile error. `uint128` is stored at 8-byte alignment, so `Value` is 24
bytes on 64-bit targets, the same as without it.

### The adapter contract

A gateway is any type with these declarations. `zom.Adapter(G)` (which
`zom.Relation` calls) checks them when it is compiled, signatures included,
and lists every problem in one error:

```
zom: gateway 'app.CsvGateway' does not satisfy the adapter contract:
  - missing `pub const adapter_name`
  - missing `pub fn deinit`
```

```zig
// The smallest gateway zom accepts: every dataset is empty, and with no
// insert, update or delete it is read-only.
const EmptyGateway = struct {
    pub const adapter_name = "empty";
    pub const Config = struct {};

    pub fn init(_: std.mem.Allocator, _: Config) @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}

    pub fn Dataset(comptime S: type) type {
        return struct {
            const Q = zom.Query(S.Tuple);

            pub fn read(_: *@This(), _: Q, allocator: std.mem.Allocator) ![]S.Tuple {
                return allocator.alloc(S.Tuple, 0);
            }
            pub fn count(_: *@This(), _: Q) !usize {
                return 0;
            }
        };
    }

    pub fn dataset(_: *@This(), comptime S: type) !*Dataset(S) {
        const static = struct {
            var instance: Dataset(S) = .{};
        };
        return &static.instance;
    }
};
```

In full, with `Q = zom.Query(S.Tuple)`:

| Declaration | Signature | Required? | Contract |
|---|---|---|---|
| `Gateway.adapter_name` | a string | yes | Names the adapter in error messages. |
| `Gateway.Config` | a type | yes | What `init` takes. |
| `Gateway.init` | `fn (Allocator, Config) Gateway` or `!Gateway` | yes | |
| `Gateway.deinit` | `fn (*Gateway) void` | yes | Frees everything the gateway owns. |
| `Gateway.Dataset` | `fn (comptime S: type) type` | yes | The dataset type for schema `S`. |
| `Gateway.dataset` | `fn (*Gateway, comptime S: type) !*Dataset(S)` | yes | Returns the same dataset every time for the same `S`. |
| `Gateway.transaction` | `fn (*Gateway, ctx: anytype, comptime f: anytype) R` | no, `.transaction` | Calls `f(ctx, tx)` with `tx: *Gateway`, the gateway to write through (zom-pg pins a connection, memory passes itself). Commits when `f` returns, rolls back when it fails and returns its error. `R` is usually `f`'s result with the gateway's errors added. Used by `Container.transaction`. |
| `read` | `fn (*Dataset, Q, Allocator) ![]S.Tuple` | yes | Applies filters, then order, then offset and limit. The caller frees the slice. |
| `count` | `fn (*Dataset, Q) !usize` | yes | The number of rows `read` would return: filters, offset and limit all apply. |
| `insert` | `fn (*Dataset, S.Tuple) !S.Tuple`, or `fn (*Dataset, S.Tuple, Allocator) !S.Tuple` | no, `.writable` | Returns the tuple as stored. `error.DuplicatePrimaryKey` on a key clash. With `strings = .caller` it must take the allocator, which owns the returned strings; `createMany` then needs `insertMany`. |
| `insertMany` | `fn (*Dataset, []const S.Tuple) !usize` | no, `.batch_insert` | Returns the tuples stored. `error.DuplicatePrimaryKey` on a key clash, with the stored rows or inside the batch. Used by `createMany`. |
| `update` | `fn (*Dataset, Q, []const Q.Change) !usize` | no, `.updatable` | Returns the rows changed. A failed update changes nothing. |
| `delete` | `fn (*Dataset, Q) !usize` | no, `.deletable` | Returns the rows removed. |
| `supports` | `zom.Supports` | no | The query features the dataset handles; the defaults when missing. A strict relation that uses one left out does not compile; see [Query support](#query-support-strict-and-fallback). |
| `filterable` | `fn (comptime field: []const u8, comptime op: zom.Op) bool` | no | Narrows `supports` per attribute, for a backend that only filters on some (TigerBeetle filters transfers on `ledger` and `code`, not `amount`). Called at compile time, only for ops `supports` allows; false makes that filter unsupported. Without it, every attribute is filterable. |
| `orderable` | `fn (comptime field: []const u8) bool` | no | Narrows ordering per attribute, the same way: called for a field `supports.order_on` (or being the primary key) allows; false makes `order` by it unsupported. TigerBeetle orders by `timestamp` only, not by its key. |
| `strings` | `zom.StringOwnership` | no | `.dataset` (the default): returned strings point into the dataset. `.caller`: `read`, `readProjected` and `insert` allocate them with the allocator passed in, and every string attribute must be a slice. |
| `loadAssociation` | `fn (*Dataset, comptime a: zom.Association, keys: []const a.Key(), Q, Allocator) ![]const []const S.Tuple` | no | Loads the rows of association `a` (declared on another schema, targeting this one) for each key, instead of zom's `in` query and grouping; required to combine a `zom.customAssociation`. See [Custom associations](#custom-associations-and-loadassociation). |
| `readProjected` | `fn (*Dataset, Q, comptime P: type, Allocator) ![]P` | when `supports.projection` | The rows `read` would return, as `P`, a `zom.Project(S.Tuple, ...)` with some of the tuple's fields (copy them by name, e.g. with `zom.Mapper(S.Tuple, P, .{})`). Used by `select`. Without it, zom reads whole tuples and maps them down. |

A method may take `self` by value, `*Self` or `*const Self`. Every dataset
call is fallible, so an adapter's own errors (I/O, connection loss) flow
through `try`. Without `.writable`, `.updatable` or `.deletable`, the matching
`create`, `update` or `delete` is a compile error naming the adapter and the
relation. Zig only analyses a function that is called, so the relation still
compiles, and reads work, as long as those methods are not used:

```
zom: adapter 'csv' is read-only for relation 'users': `create` needs the `writable` capability (dataset has no `insert`)
```

An adapter with some writes but not this one says ``does not support `delete`
for relation 'users'`` instead. `commit` checks again, for a changeset built
by hand.

`createMany` needs `.batch_insert` or `.writable`. With `insertMany` it makes
one call, and what a failed batch leaves behind is up to the adapter (the
memory adapter stores all or nothing). With only `insert`, `commit` calls it
once per tuple, in order, and stops at the first error: **the tuples before
the failing one stay stored**, and the count is lost with the error. An empty
slice returns 0 without calling the dataset.

### Checking an adapter with zom.lint

`zom.lint` is the conformance suite, like rom's `ROM::Lint`. An adapter runs
it from its own tests, with a factory that says how to make a fresh gateway:

```zig
const Factory = struct {
    pub fn create(allocator: std.mem.Allocator) !zom.memory.Gateway {
        return zom.memory.Gateway.init(allocator, .{});
    }
    pub fn destroy(g: *zom.memory.Gateway) void {
        g.deinit();
    }
    // Only needed when the dataset has neither `insert` nor `insertMany`:
    // pub fn seed(g: *G, comptime S: type, rows: []const S.Tuple) !void
    // Optional, what a `createMany` with a duplicate key leaves stored:
    // pub const insert_many_on_duplicate: zom.lint.OnDuplicate = .stores_nothing;
};

test "zom.lint" {
    try zom.lint.run(zom.memory.Gateway, Factory);
}
```

Each check gets a new gateway seeded with the same six rows (`zom.lint.users`
over `zom.lint.Users`). It reads them back, filters with every `Op` on
integer, nullable, string and enum attributes (`in`/`not_in` only when the
dataset's `supports.in` is set, `like`/`ilike` only with `supports.like`),
checks `null` semantics,
ordering on one key and on several (nulls last on `.asc`, first on `.desc`), `limit` and `offset` edge
cases, `one`, and `select` through `readProjected` (with `supports.projection`
and `supports.order_on`); every case also checks that `count` equals the rows read.
The write checks cover `insert` (returns the stored tuple, a duplicate key
fails with `error.DuplicatePrimaryKey`), `createMany` (the count, both kinds
of duplicate key, and what a failure leaves stored: nothing by default with
`insertMany`, the tuples before the failing one with the `insert` fallback,
or whatever the factory's `insert_many_on_duplicate` says), `update` (the
count, a key clash, `error.ValueOutOfRange` for a runtime value that does not
fit, and that a failed update changes nothing) and `delete` (the count, the
rows are gone, `count` agrees). Strings written by `insert`, `createMany` and
`update` must be copied: the caller's buffer is overwritten afterwards. Error
checks go through `zom.lint.expectSharedError(label, error.X, result)`, which
fails when the call's error set has no `error.X` (found at compile time) or
when it returns another name, so an adapter must use the shared names from
`zom.adapter.Error`.
All checks run; each failure prints the check's name and case, and `run`
returns the first error. A check that needs a capability or a `zom.Supports`
feature the dataset lacks is skipped with a `skipped:` line. Everything goes
through `std.testing.allocator`, so leaks fail the test too.

Note that `zig build test` shows any test's stderr under a `failed command:`
header even when every test passes, so an adapter whose checks get skipped
will see that header on a green run.

### Writing an adapter

rom ships each adapter as its own gem (rom-csv next to rom-core). zom keeps
the same separation in the code but ships one package with several modules,
because a Zig package is a whole repo (or tarball) root: an adapter in a
subdirectory can't be fetched on its own, and splitting into repos would
mean releasing several of them in lockstep for every 0.x API change. An
application depends on zom once and picks the modules it uses:

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
const zom = dep.module("zom");
const zom_csv = dep.module("zom_csv"); // also zom_yaml, zom_sql
```

`zom_pg` needs pg.zig, which is a lazy dependency, so it exists only when
asked for: `b.dependency("zom", .{ ..., .pg = true })`. Applications that
don't use Postgres never fetch pg.zig. In a checkout of zom, `-Dpg` is on by
default; `-Dpg=false` leaves zom-pg out. `zom_tigerbeetle` works the same
way with `.tigerbeetle = true` (`-Dtigerbeetle`), for TigerBeetle's
prebuilt C client.

Each adapter's code lives in `adapters/<name>/src`, and the root `build.zig`
exports `adapters/<name>/src/root.zig` as the module `zom_<name>`:

```
adapters/csv/
└── src/root.zig    pub const Gateway = struct { pub const adapter_name = "csv"; ... }
```

An adapter imports zom only through `@import("zom")` (and other adapters
through theirs, as zom-pg imports `zom_sql`), never by relative path into
`src/`. That keeps the public API the whole contract, and lets an adapter
move to a repo of its own later without code changes, if it ever needs its
own release schedule (see plan.md, section 3.2).

To add an adapter: create `adapters/<name>/src/root.zig`, add one
`addAdapter` call in the root `build.zig` (with the modules it imports),
and add `adapters/<name>/src` to `.paths` in `build.zig.zon`. A third-party
adapter can still be its own package: depend on zom and import
`dep.module("zom")` the same way.

A file adapter (one that loads files into `zom.memory.Store`) doesn't write
a gateway at all. It writes a `Format` with `load` and `dump`, and
`zom.file.Gateway(Format, .read_only)` / `.writable` supply the rest:
finding the file, loading each dataset once, the read-only and writable
dataset types, and the atomic `sync`. zom-csv and zom-yaml are both built
this way. The contract is listed in `src/file.zig` and checked with
`@hasDecl` when the gateway type is built.

`zig build test-adapters` runs every adapter's tests, `zig build test-pg`
only zom-pg's, `zig build test-tigerbeetle` only zom-tigerbeetle's, and `zig build test` runs them all along with the core.
Every adapter's tests should call `zom.lint.run` once it can store the lint
seed rows.

### zom-sql

`adapters/sql` is the SQL half of rom-sql that needs no driver: it compiles a
relation's query into a `SELECT`, and inserts, updates and deletes into
`INSERT`, `UPDATE` and `DELETE`, each with its bind parameters, for a `Dialect`.
A gateway such as the planned zom-pg pairs it with a driver.

```zig
const zom_sql = @import("zom_sql");

const compiled = try zom_sql.compileRelation(.postgres, allocator, users.where(.age, .gte, 18).select(.{ .id, .name }));
defer compiled.deinit(allocator);
// compiled.sql:    SELECT "id", "name" FROM "users" WHERE "age" >= $1
// compiled.params: .{ .{ .int = 18 } }
```

| Declaration | What it is |
|---|---|
| `Dialect` | `placeholder` (`.dollar_n` for `$1`, `.question` for `?`), `quote` (default `'"'`), `returning`, `ilike`, `nulls_order` (understands `NULLS LAST`, default true) and `limit_all` (what goes after `LIMIT` when there is only an offset; `null` when a bare `OFFSET` is valid), and `max_params`, the most bind parameters one statement may carry (no default). `returning` adds `RETURNING *` to inserts. Presets: `Dialect.postgres` (65535 parameters) and `Dialect.sqlite` (32766, SQLite 3.32+). Always a comptime argument, so each dialect gets its own compiler. |
| `compileRelation(dialect, allocator, relation) !Compiled` | The relation's schema name is the table and its `Output` (the tuple, or what `select` kept) the columns. |
| `compileSelect(dialect, T, allocator, table, query) !Compiled` | Every field of `T`. |
| `compileProjected(dialect, T, Out, allocator, table, query) !Compiled` | Only `Out`'s fields, e.g. `zom.Project(T, .{ .id })`. |
| `Compiled` | `sql: []u8` and `params: []zom.Value`, one per placeholder, in order. Free with `deinit(allocator)`. String params borrow from the query. |
| `writeSelect(dialect, T, Out, writer, *Params, table, *const query) RenderError!void` | Renders into any `*std.Io.Writer`; what the `compile*` functions use. |
| `writeIdent(dialect, writer, name)` | Writes a quoted identifier, doubling any quote inside it. |
| `compileInsert(dialect, T, allocator, table, row) !Compiled` | `INSERT INTO "t" ("a", "b") VALUES ($1, $2)`, every field of `T`, plus ` RETURNING *` when `dialect.returning`. |
| `compileInsertMany(dialect, T, allocator, table, rows) !Batch` | Multi-row `VALUES (...), (...)`, split into as many statements as it takes to keep each under `dialect.max_params`: `rowsPerStatement(dialect, T)` rows each, `@divFloor(max_params, fields)` (a tuple too wide for one row is a compile error). Each statement numbers its placeholders from `$1`; run them in order, in a transaction if the batch must be all or nothing. No rows is no statements. |
| `Batch` | `statements: []Compiled`, in row order. `deinit(allocator)` frees every statement and the slice. |
| `compileUpdate(dialect, T, allocator, table, query, changes) WriteError!Compiled` | `UPDATE "t" SET "a" = $1 WHERE ...`, with `changes: []const Query(T).Change` (an `Update` changeset's `changes[0..change_count]`). Placeholders run on from `SET` into `WHERE`. A field set twice takes its last value, as in memory. |
| `compileDelete(dialect, T, allocator, table, query) WriteError!Compiled` | `DELETE FROM "t" WHERE ...`. |
| `writeInsert`, `writeUpdate`, `writeDelete` | The write statements rendered into any writer, like `writeSelect`. |

String params borrow from what was passed in: the query for a `SELECT`, the
tuples for an insert, the changes and the query for an update. Values go
through `zom.query.toValue`: optional fields set to null bind `.null`, and
enums bind their tag name.

**Unfiltered writes are refused.** `compileUpdate` and `compileDelete` return
`error.UnboundedWrite` for a query with no filters or join, so a forgotten `where`
can't empty or rewrite a table. Set `query.all = true` to mean it. `order`,
`limit` and `offset` don't count as filters, and the write statements ignore
them, as the memory adapter does. An update with no changes is
`error.EmptyUpdate`, since `SET` needs a column; nothing would change, and
`update().commit()` already skips it.

Every identifier is quoted. Every node of the query is rendered: `AND` / `OR`
groups in parentheses, `NOT (...)`, `IN (...)`, `LIKE ... ESCAPE '\'`
(`ILIKE`, or `LOWER(x) LIKE LOWER(y)` without it), `BETWEEN`, `IS [NOT] NULL`,
several `ORDER BY` keys, `LIMIT` and `OFFSET`. The SQL is true, false or
unknown exactly where the memory adapter's `Query.truth` is:

- `IN ()` is not valid SQL, so an empty `in` is `1=0` and an empty `not_in`
  `1=1`. On a nullable attribute they are `(x IS NULL AND NULL)` and
  `(x IS NOT NULL OR NULL)`, which stay unknown for a null, as in memory, so
  `whereNot` of either still skips null rows.
- A nullable sort key says where its nulls go: `ASC NULLS LAST`, `DESC NULLS
  FIRST`, matching memory (and Postgres's default, which SQLite's isn't).
- `limit` and `offset` are clamped to the largest bigint, since Postgres
  rejects `LIMIT 18446744073709551615`.

Remaining differences come from the database, not the SQL: an enum stored as
text sorts by name rather than declaration order; SQLite's `LIKE` ignores
ASCII case unless `PRAGMA case_sensitive_like = ON`; and Postgres rejects a
pattern ending in a lone `\`, which memory reads as a literal `\`.

`error.InvalidNullComparison` is returned for `lt` / `lte` / `gt` / `gte`
against `null`. (`eq null` and `neq null` are `IS NULL` and `IS NOT NULL`.)

### zom-pg

`adapters/pg` is a gateway for PostgreSQL on
[pg.zig](https://github.com/karlseguin/pg.zig): a connection pool,
statements from zom-sql, `zom.Value` params bound through `pg.Stmt`, and
rows decoded by column name. Its strings are caller-owned (see
[Memory rules](#memory-rules)). Setup, type mapping and errors are in
[adapters/pg/README.md](adapters/pg/README.md).

```zig
var pg = try zom_pg.Gateway.init(allocator, .{ .io = io, .url = "postgres://app@localhost/app" });
defer pg.deinit();
const users = try zom.Relation(UserSchema, zom_pg.Gateway).init(&pg);
```

### zom-tigerbeetle

`adapters/tigerbeetle` is a gateway for [TigerBeetle](https://tigerbeetle.com)
on its C client, `tb_client`, which comes prebuilt and is linked as a
static library. TigerBeetle's own releases pin an older Zig than 0.16, so
zom can't build them from source. The schemas are fixed:
`zom_tigerbeetle.Account` and `zom_tigerbeetle.Transfer`, over the client's
own structs, keyed by the `u128` `id`. Records are immutable, so there is
no `update` or `delete`. `create` and `createMany` run `create_accounts` /
`create_transfers`, split into batches the cluster takes, and each of
TigerBeetle's result codes is a typed error (`error.ExceedsCredits`, ...).
`byPk` and `where(.id, .in, ...)` are `lookup_*`. Equality on
`user_data_128/64/32`, `ledger` and `code`, and `timestamp` ranges, are
`query_*`, ordered by `timestamp` either way and paged through. Any other
filter or order, and `offset`, is a compile error unless the relation
`allowFallback()`s. `relation.linked()` takes the place of a transaction:
a chain of events created all or nothing. What is and isn't supported (and
why), the dependency decision, the supported targets and the setup are in
[adapters/tigerbeetle/README.md](adapters/tigerbeetle/README.md).
[examples/double_entry](examples/double_entry/src/main.zig) is a small
ledger through zom only, run in zom-tigerbeetle's CI workflow against a dev
cluster (`cd examples/double_entry && TB_ADDRESSES=3000 zig build run`).

```zig
var tb = try zom_tigerbeetle.Gateway.init(allocator, .{ .io = io, .cluster_id = 0, .addresses = "3000" });
defer tb.deinit();
const accounts = try zom.Relation(zom_tigerbeetle.Account, zom_tigerbeetle.Gateway).init(&tb);
_ = try accounts.create(.{ .id = 1, .ledger = 700, .code = 10 }).commit();
const newest = try accounts.where(.ledger, .eq, 700).order(.timestamp, .desc).limit(10).toSlice(allocator);
```

### Errors

| Error | Returned by |
|---|---|
| `error.DuplicatePrimaryKey` | `create(...).commit()`, `createMany(...).commit()`, or an update that sets the primary key to one already in use (or sets it on more than one row). |
| `error.ValueOutOfRange` | `update().set(...).commit()` with a runtime value that does not fit the attribute, e.g. a `u32` holding 300 set on a `u8`. |
| `error.MoreThanOneTuple` | `one`. |
| `error.DatasetTypeMismatch` | `memory.Gateway.dataset` (and so `Relation.init`), when two different schema types share a dataset name. |
| `error.UnboundedWrite` | zom-sql's `compileUpdate` and `compileDelete`, for a query with no filters or join and `all` not set. |
| `error.ScanLimitExceeded` | zom-tigerbeetle's reads and counts, after fetching `Config.scan_max` records without finishing. |
| `error.EmptyUpdate` | zom-sql's `compileUpdate`, with no changes. |
| `error.UnsupportedFilter` | `update().commit()` and `delete()` on a `.fallback` relation with a filter its dataset can't evaluate. |
| `error.JoinUnavailable` | A join read on a `memory.Store` that no `memory.Gateway` handed out, so it has no other dataset to join. |
| `error.OutOfMemory` | Anything that takes or uses an allocator. |

`zom.adapter.Error` reserves the names every adapter uses for the same
condition (`DuplicatePrimaryKey`, `ValueOutOfRange`, `NotFound`, `ReadOnly`,
`ConnectionFailed`); its doc comments say when each one applies.

### Planned changes

These are scheduled in [plan.md](plan.md) and will each come with a version
bump and a changelog entry:


## Memory rules

- `toSlice`, `mapTo`, `mapWith` and `Mapper.many` return slices the caller
  owns. zom-sql's `compile*` functions return a `Compiled` that the caller
  frees with `compiled.deinit(allocator)`.
- Every adapter copies string attributes on insert and update, so input
  buffers can be reused straight away.
- Who owns the strings you read back depends on the adapter's
  `zom.StringOwnership`. With `.dataset` (memory, CSV, YAML) they point into
  the dataset and stay valid as long as the gateway lives. With `.caller`
  (zom-pg) they are allocated with the allocator you passed to the read (or
  to `commitAlloc`) and are yours. Code that should run on any adapter frees
  with the relation:

  ```zig
  const rows = try users.toSlice(allocator);
  defer users.free(allocator, rows); // allocator.free(rows) on memory
  if (try users.byPk(1).one(allocator)) |u| {
      defer users.freeOne(allocator, u); // a no-op on memory
  }
  const stored = try users.create(tuple).commitAlloc(allocator);
  defer users.freeOne(allocator, stored);
  ```

  zom frees the strings it drops along the way (rows filtered out in memory
  by a `.fallback` read, attributes `select` leaves out, the extra row
  `one` reads). After `mapTo` / `mapWith`, the strings the mapper copied
  belong to the entities (`zom.strings.freeAll(E, allocator, entities)`
  frees them); the rest are freed. An arena per request avoids all of this.
- `createMany` does not copy the slice you pass; keep it alive until
  `commit`. The tuples' strings are copied on commit, as with `create`.
- A relation does not copy the values you filter on. A string passed to
  `where`, and the slice passed to `whereIn` / `whereNotIn`, must stay alive
  and unchanged until the relation (and every relation chained from it) is
  last used. A tuple given to `where(.x, .in, .{ ... })` has no such limit:
  its values are comptime-known and stored statically.
- The gateway must outlive every relation made from it, and
  `memory.Gateway.deinit` frees all of its datasets at once.
- `relation.combine(...).mapTo` returns a `zom.CombineResult` whose
  `deinit()` frees every slice and string in it. For the deprecated
  `combineMany`, use an arena: it allocates one child slice per parent.

## Memory adapter semantics

- The primary key is unique: `create` or `update().set(.id, ...)` returns
  `error.DuplicatePrimaryKey` instead of storing a second row with that key.
- An update checks every change before writing, so a rejected update leaves
  every row as it was.
- `insertMany` (and so `createMany`) is all or nothing: it checks every key,
  against the stored rows and inside the batch, and reserves room for every
  row before storing any, so a duplicate key or running out of memory stores
  none of them.
- `order` sorts nulls the way Postgres does: last on `.asc`, first on `.desc`.
  With several keys, each later key only orders rows tied on the earlier ones.
  The memory adapter sorts with `std.mem.sort`, which is stable, so rows equal
  on every key (or every row, with no order) keep their insertion order. Other
  adapters need not: as in SQL, add a unique key such as the primary key last
  when the order of ties matters.
- `count` and `delete` return `!usize` like every other dataset call, because
  real adapters do I/O for them. The memory adapter never fails, but callers
  still write `try users.count()`.
- `count` applies `limit` and `offset`, so it always equals the length of
  `toSlice`. `update` and `delete` ignore them for now.
- It passes `zom.lint`.

## Roadmap

[plan.md](plan.md) lays out the path from this toolkit to a core with
separate adapters, the way rom-core pairs with rom-sql, rom-csv and
rom-yaml:

0. Tidy the core and freeze the API as v0.2. *Done in 0.2.0.*
1. Adapter contract, `zom.lint` conformance suite, and `zom.Container`.
2. `zom-csv` and `zom-yaml`, built on the memory engine.
3. `zom-sql` compiler and the `zom-pg` driver on `karlseguin/pg.zig`,
   with projections and a richer query AST. *zom-sql is in `adapters/sql`
   and zom-pg in `adapters/pg`; transactions and CI against a Postgres
   container are next.*
4. Associations in the schema, and `combine` with one `IN (...)` query
   instead of the O(n·m) `combineMany`, now deprecated.
5. Repositories, transactions and plugins (timestamps, pagination).
   *Done: repositories, `container.transaction`, the `timestamps` and
   instrumentation plugins, pagination, and the
   [Postgres example](#a-repository-and-a-transaction-on-postgres).*
6. `zom-tigerbeetle` on the native Zig client: immutable accounts and
   transfers, batched writes.

## Contributing

New contributors are welcome, including people who are new to Zig. Work is
tracked as [GitHub issues](https://github.com/kamalogudah/zom/issues), grouped
into [milestones](https://github.com/kamalogudah/zom/milestones) that follow the
phases in [plan.md](plan.md). Every ticket lists the Zig concepts it needs, with
links to the topics below.

### 1. Set up

1. Install **Zig 0.16.0** exactly (`build.zig.zon` sets `minimum_zig_version = "0.16.0"`). Get it from https://ziglang.org/download/, or use a version manager like [`zvm`](https://github.com/tristanisham/zvm) or [`anyzig`](https://github.com/marler8997/anyzig).
2. Check it: `zig version` should print `0.16.0`.
3. Clone and run the tests:
   ```sh
   git clone git@github.com:kamalogudah/zom.git
   cd zom
   zig build test
   ```
   If nothing is printed and the exit code is 0, every test passed. Add `--summary all` to see each step.
4. Editor support: install [ZLS](https://github.com/zigtools/zls) built for 0.16, which gives you go-to-definition into the standard library. That's the fastest way to learn the std API.

### 2. A tour of the code (about 1,400 lines, a third of them tests)

| File | What it does | Read it for |
|---|---|---|
| `src/root.zig` | Public API: re-exports everything | How a Zig package exposes modules |
| `src/schema.zig` | `Schema(T, name, pk)` returns a type | Functions that return types (generics) |
| `src/query.zig` | `Value` union, `Query(T)`, filter matching, compile-time type checks | Tagged unions, `@typeInfo`, `@compileError` |
| `src/adapter.zig` | `Adapter(G)`: checks the adapter contract and finds a gateway's capabilities | `@hasDecl`, `@typeInfo(...).@"fn"`, building comptime strings |
| `src/lint.zig` | `lint.run(G, Factory)`: the conformance suite every adapter runs | Tests as library code, `inline for` over a tuple of generic functions |
| `src/relation.zig` | `Relation(S, Gateway)`: immutable query builder | Comptime field enums, `anytype`, a type parameter with a default through a wrapper (`Relation` calls `RelationOf`) |
| `src/projection.zig` | `Project(T, fields)`: the narrower struct `select` reads into | `@Struct`, field defaults in reflection, memoised comptime calls |
| `src/container.zig` | `Container(spec)`: gateways and relations declared once, init/deinit in one place | Building struct types with `@Struct`, `errdefer` with a counter in an `inline for` |
| `src/repository.zig` | `Repository(App, spec)`: a root relation with command shortcuts, and wrapper structs for custom views | `@Struct`, `@FieldType`, `@TypeOf` in return types, forwarding methods by hand |
| `src/changeset.zig` | `Create`, `CreateMany` and `Update` changesets | Fixed-capacity arrays, slices, comptime capability branching |
| `src/mapper.zig` | Copies tuples into domain structs | `inline for` over struct fields |
| `src/codec.zig` | Text cells to typed fields and back, with a `Diagnostic` out-parameter | `@typeInfo` dispatch, mapping error sets with `catch \|e\| switch`, the diagnostics pattern, `std.Io.Writer` and shortest round-trip float formatting |
| `src/adapters/memory.zig` | In-memory gateway and dataset | Allocators, arenas, `ArrayList`, hash maps, type erasure with `*anyopaque` |
| `src/tests/` | Tests, one file per layer, with shared `fixtures.zig` | `std.testing` |
| `examples/readme.zig` | Every README code block, compiled by `zig build test` | Using zom as a package import |
| `examples/csv_users/` | A program joining CSV users with in-memory posts through `zom.Container`, run and checked by `zig build test` | `b.addExecutable`, `pub fn main(init: std.process.Init)`, writing to stdout |
| `tests/compile_errors/` | Code that must *not* compile, checked by `zig build compile-errors` | What `@compileError` messages users see |
| `src/file.zig` | `zom.file`: the gateway and datasets file adapters share, over a `Format` (load and dump) | Comptime-parameterised generics, duck typing checked with `@hasDecl`/`@hasField`, atomic writes (temp file, fsync, rename) |
| `adapters/csv/` | The `zom_csv` module, a CSV `Format` for `zom.file` | Modules and imports in `build.zig`, `b.dependency(...).module(...)` |
| `adapters/sql/` | The `zom_sql` module: compiles a query to SQL for a comptime `Dialect` | Comptime struct parameters, rendering into a `*std.Io.Writer`, recursion with an explicit error set, multiline string literals in tests |
| `adapters/yaml/` | The `zom_yaml` module: a YAML-subset parser and writer, and a YAML `Format` for `zom.file` | A hand-written line parser, arenas, escaping that round-trips |

### 3. Zig concepts used everywhere in zom

The language reference for this version is https://ziglang.org/documentation/0.16.0/ (called **langref** in the tickets). Also useful: [ziglang.org/learn](https://ziglang.org/learn/), and the standard library source, which lives under `lib/std/` next to your `zig` binary (`zig env` prints the path).

- **Comptime and generic types.** `Schema`, `Query`, `Relation` and `Mapper` are all *functions that return a `type`*. They run at compile time. See langref [comptime](https://ziglang.org/documentation/0.16.0/#comptime) and [Generic Data Structures](https://ziglang.org/documentation/0.16.0/#Generic-Data-Structures).
- **Reflection.** `@typeInfo(T)` returns a tagged union describing a type (struct fields, int signedness and bits, optional child type and so on). zom uses it to inspect your tuple struct. See [@typeInfo](https://ziglang.org/documentation/0.16.0/#typeInfo), [@FieldType](https://ziglang.org/documentation/0.16.0/#FieldType), [@field](https://ziglang.org/documentation/0.16.0/#field), [@hasDecl](https://ziglang.org/documentation/0.16.0/#hasDecl) and [@hasField](https://ziglang.org/documentation/0.16.0/#hasField).
- **`inline for` and `inline else`.** These unroll a loop or a switch at compile time, so every iteration can use a different type. `switch (field) { inline else => |tag| ... }` turns a runtime enum value into a comptime one. See [inline for](https://ziglang.org/documentation/0.16.0/#inline-for) and [Inline Switch Prongs](https://ziglang.org/documentation/0.16.0/#Inline-Switch-Prongs).
- **Custom compile errors.** `@compileError("...")` is how zom rejects bad queries at build time. See [@compileError](https://ziglang.org/documentation/0.16.0/#compileError).
- **Errors.** `!T`, `try`, `catch`, `errdefer`, error sets and inferred error sets. See [Errors](https://ziglang.org/documentation/0.16.0/#Errors) and [errdefer](https://ziglang.org/documentation/0.16.0/#errdefer).
- **Allocators.** Nothing allocates behind your back. Any function that returns heap memory takes a `std.mem.Allocator`, and the caller frees the result. In tests, use `std.testing.allocator`, which fails the test if you leak memory. See [Memory](https://ziglang.org/documentation/0.16.0/#Memory) and [Choosing an Allocator](https://ziglang.org/documentation/0.16.0/#Choosing-an-Allocator).
- **Unmanaged containers.** In 0.16, `std.ArrayList(T)` doesn't store its allocator. You start it with `.empty` and pass the allocator to each call: `list.append(gpa, x)`, `list.deinit(gpa)`.
- **Tagged unions.** `Value` is `union(enum)`. Use `switch` to read it. See [Tagged union](https://ziglang.org/documentation/0.16.0/#Tagged-union).
- **Optionals.** `?T`, `orelse`, `if (x) |v|`. See [Optionals](https://ziglang.org/documentation/0.16.0/#Optionals).
- **Tests.** `test "name" { ... }` blocks, `try std.testing.expectEqual(...)`. See [Zig Test](https://ziglang.org/documentation/0.16.0/#Zig-Test).
- **Build system.** `build.zig` and `build.zig.zon`. See [Zig Build System](https://ziglang.org/learn/build-system/).

### 4. How we work

- Pick an issue in the earliest open milestone, and comment on it to claim it. Tickets labelled `difficulty: beginner` are the best first ones.
- One issue per PR. Reference it with `Closes #N`.
- `zig build test` must pass, and run `zig fmt src` (or `zig fmt .`) before you push.
- Follow the project's principles ([plan.md](plan.md) section 6): compile-time checks first, explicit fixed limits, relations stay plain values, callers own allocations, and adapters must pass `zom.lint`.
- Match the surrounding style: doc comments (`//!` at file level, `///` on declarations) explain *why*, and the rom equivalent is named where there is one.
- Stuck? Comment on the issue with what you tried and the exact compiler error. Zig's errors usually point at the right line, so include the whole message.

### Compile-error tests

Many of zom's guarantees are things that don't compile, and `zig test` can't express that. Each file in `tests/compile_errors/` imports `zom`, does one illegal thing, and starts with the error text it must produce:

```zig
// expect: zom: attribute 'age' is not optional, null is not allowed
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32, age: u8 };
const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.where(.age, .eq, null);
}
```

`zig build compile-errors` (also run by `zig build test`) compiles every case and fails if one compiles, or if its stderr doesn't contain the `// expect:` text. For a multi-line error, start the file with several `// expect:` lines (one per line of the message, without its indentation); each must appear in stderr, as in `adapter_missing_decls.zig`. To add a case, drop a new `.zig` file in the folder; `build.zig` picks it up. Put the illegal code inside an `export fn` so the compiler analyzes it, and copy the expected text from the real error (types declared in the case show up as `<file name>.<Type>`). The cases build zom with `-Dno-deprecated` on, so a case can't lean on a deprecated declaration, and `combine_many_deprecated.zig` checks that error. To reproduce one by hand, give zom its `build_options` module:

```sh
echo 'pub const no_deprecated: bool = true;' > /tmp/build_options.zig
zig build-obj -fno-emit-bin --dep zom -Mroot=tests/compile_errors/null_on_non_optional.zig \
  --dep build_options -Mzom=src/root.zig -Mbuild_options=/tmp/build_options.zig
```

### 5. Good first tickets

Look for the [`good first issue`](https://github.com/kamalogudah/zom/labels/good%20first%20issue) label in the **Phase 0** milestone. Those tickets fix real bugs in code under 300 lines long, and each one comes with a failing test you can write first.
