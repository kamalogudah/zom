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
compiled and run by that command, from [examples/readme.zig](examples/readme.zig).

### A longer tour

Continuing from the block above:

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
| `zom.Schema(T, name, pk, options)` | Returns a schema type with `Tuple = T`, `name` (the dataset name), `primary_key` (a field of `T`, as an enum literal) and its associations. `options` is `.{}` or `.{ .associations = ... }`; see [Associations](#associations). |
| `zom.hasMany(Target, .fk)`, `zom.belongsTo(Target, .fk)` | Declare an association on a schema. `S.association(.name)` and `S.associations.name` return a `zom.Association`: `name`, `kind` (`zom.AssociationKind`: `has_many` or `belongs_to`), `source`, `target`, `foreign_key` and `primary_key` (field names as strings), plus `Child()` and `Parent()`. |
| `zom.Relation(S, Gateway)` | Returns an immutable relation type over schema `S` and an adapter's `Gateway`. Checks the [adapter contract](#the-adapter-contract) at compile time through `zom.Adapter(Gateway)`, which it exposes as `Relation.Adapter`. |
| `zom.RelationOf(S, Gateway, Output)` | The strict relation type whose reads return `Output`. `Relation(S, G)` is `RelationOf(S, G, S.Tuple)`, and `select` returns `RelationOf(S, G, Project(S.Tuple, fields))`. Exposes `Tuple`, `Output`, `projected` and `mode`. |
| `zom.RelationWith(S, Gateway, Output, mode)` | The relation type with every parameter. `RelationOf(S, G, Out)` is `RelationWith(S, G, Out, .strict)`, and `allowFallback()` returns `RelationWith(S, G, Out, .fallback)`. |
| `zom.Mode` | `strict` or `fallback`: what a relation does with query features its dataset does not support. See [Query support](#query-support-strict-and-fallback). |
| `zom.Scan`, `zom.ScanHook` | What a `.fallback` read that ran in memory reports (`adapter`, `relation`, `rows_fetched`, `rows_returned`), and the `*const fn (Scan) void` it reports to. |
| `zom.Project(T, .{ fields })` | The struct `select` reads into: only `fields` of `T`, in the order given, with their types and defaults. An empty tuple, an unknown field or a repeated one is a compile error. Equal arguments return the same type. |
| `zom.Adapter(G)` | Checks gateway `G` against the [adapter contract](#the-adapter-contract), reporting every problem in one compile error. Has `Gateway`, `name` (`G.adapter_name`), `Dataset(S)` (checks the dataset for schema `S`), `capabilities(S) Capabilities`, `has(S, cap) bool`, `readOnly(S) bool`, `require(S, cap, method)`, `supports(S) Supports`, and `filterGap(S, field, op)` / `orderGap(S, field)`, which return null when the dataset can evaluate that filter or sort key, else why not. |
| `zom.Supports` | The query features a dataset evaluates itself: `or` (boolean groups), `in` (`in`, `not_in`), `like` (`like`, `ilike`), `order_on` (order by any attribute, not only the key), `offset`, `projection`, `join` (`relation.join`). `Supports.all` sets them all. |
| `zom.Join`, `zom.JoinFilter` | What `relation.join(.assoc)` stores in `query.join`: the association's name, the joined table, the key column on each side and up to `Join.max_filters = 8` `whereJoined` filters, each by column name. Plain data, so a query is still copied by value without allocating; `join.targetQuery(C)` gives the filters back as a `zom.Query(C)`. Only an adapter with `supports.join` reads it. |
| `zom.Capability` | `writable`, `batch_insert`, `updatable`, `deletable`, `transaction`. |
| `zom.StringOwnership` | `dataset` or `caller`: who frees the strings in the tuples a dataset returns. See [Memory rules](#memory-rules). |
| `zom.strings` | Helpers for caller-owned strings: `freeFields(T, allocator, item, keep)` frees an item's string attributes except those named in `keep`, `freeAll(T, allocator, items)` frees every item's strings and the slice, and `dupeFields(T, allocator, item)` copies them (freeing its copies on error). |
| `zom.Capabilities` | A struct with one `bool` per `Capability`, all `false` by default. |
| `zom.adapter` | The module behind `Adapter`, `Capability` and `Capabilities`. |
| `zom.Query(T)` | The adapter-neutral query a relation builds: a filter tree, sort keys (`orders`, at most `max_orders = 4`, read through `orderSlice()`, most significant first), `limit: ?usize`, `offset: usize`, and `all: bool` (default false: set it to say an update or delete with no filters is meant to touch every row, which [zom-sql](#zom-sql) otherwise refuses; it changes nothing about which rows match). The tree is stored flat so a copy is a full copy: `filters` (at most `max_filters = 16`) and `nodes` (at most `max_nodes = 32`: filters plus `any` / `all` / `not` groups, which refer to children by index), AND-ed at the top level. An adapter without `or` support reads an AND-only query through `filterSlice()` (it asserts `isConjunction()`); one with it walks `nodeSlice()` from `topNodes()`. `matches(row)` and `truth(row) ?bool` evaluate the query in memory with SQL's three-valued logic, alongside `lessThan(orders, a, b)` (the comparator for `std.mem.sort(T, rows, query.orderSlice(), lessThan)`: key by key, the next key breaking ties), `orderBy(order, a, b)` (one key) and `fieldValue(row, field)`. Nested types: `Field` (enum of `T`'s fields), `Filter` (`field`, `op`, `operand`), `Node` (`filter`, `and_group`, `or_group`, `not`), `Children`, `Order`, `Change`. `max_in = 64` bounds one `in` list. The query also builds itself, with the same `where` / `whereIn` / `whereNotIn` / `whereAny` / `whereNot` / `order` / `reorder` as a relation (and `addOrder`), so adapters and tests can make one without a gateway. |
| `zom.any(conds)`, `zom.all(conds)`, `zom.not(cond)` | Boolean groups to nest inside `whereAny` / `whereNot`. A condition is `.{ field, op, value }` or another group. |
| `zom.Value` | The runtime value carried by filters and changes. See [Value](#value). |
| `zom.Op` | Filter operators: `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `in`, `not_in`, `like`, `ilike`, `between`, `is_null`, `is_not_null`. `op.operand()` returns the `Operand` variant it takes. |
| `zom.Direction` | `asc`, `desc`. |
| `zom.Container(spec)` | Declares gateways and relations once; `init(self, allocator, Config)` / `deinit()` connect and disconnect them all. See [Container](#container). |
| `zom.Repository(App, .{ .root, .relations })` | Groups some of a container's relations around a root relation: `init(&app)`, `relations` (one field per relation, or its wrapper struct), `root()`, and the root shortcuts `byPk`, `where`, `all`, `create`, `createMany`, `update`, `delete`. See [Repository](#repository). |
| `zom.changeset` | `Create(Rel)`, `CreateMany(Rel)`, `Update(Rel)` and `Scoped(Rel, keys)`, the types returned by `relation.create`, `relation.createMany`, `relation.update` and `relation.associate`. You don't name them yourself; `Scoped`'s `Input` is the struct its `create` takes. |
| `zom.Mapper(Src, Dst, .{ .renames, .skip })` | A comptime mapper: `call(src) Dst` and `many(allocator, srcs) ![]Dst`. A `Dst` field takes the `Src` field of the same name (or its rename), else its default; neither is a compile error. Fields named in `skip` are left undefined for the caller to fill. `sources` lists the `Src` fields it copies, and `options` the options it was made with. |
| `zom.Combined(Source, association, Target)`, `zom.CombineResult(E)` | What `relation.combine(.assoc, target)` returns, and what its `mapTo` / `mapWith` return: `items: []E` and the arena owning them, freed with `deinit()`. See [Associations](#associations). |
| `zom.combineMany(.{ .into, .parent_key, .child_key }, allocator, parents, children)` | **Deprecated:** use `relation.combine`. Sets `parent.into` to the children whose `child_key` equals the parent's `parent_key`, on slices already loaded, in O(n·m). Build with `-Dno-deprecated` to make each call a compile error. |
| `zom.mapper` | The module behind `Mapper` and `combineMany`, with their option types `Options`, `Rename` and `CombineOptions`. |
| `zom.codec` | Text cells to field values, for adapters whose rows arrive as strings. `decodeField(F, text, opts) !F` decodes one cell, and `decodeRow(T, cells, opts, ?*Diagnostic) !T` decodes a row, in field order or through `Options.columns`. `Options.null_text` (default `""`) means null. Strings borrow the cells. On error the `Diagnostic` has `row`, `column`, `field`, `text` and `err`, and formats with `{f}` as `14:3 (age): "abc" is not an integer from 0 to 255`. The other way, `encodeField(writer, value, opts)` and `encodeRow(writer, T, row, opts, sep)` write values back so they decode to the same thing: ints `{d}`, floats in their shortest round-trip form (decimal, or scientific outside `1e-6`..`1e21`), `true`/`false`, tag names, strings as they are, `null` as `null_text`. Nothing is quoted; that is the format writer's job. The accepted spellings are listed in `src/codec.zig`. |
| `zom.memory` | The in-memory adapter: `Gateway` (`adapter_name = "memory"`, `Config = struct {}`, `init(allocator, Config)`, `deinit()`), whose dataset is `Store(S)`. Every capability except `transaction`. |
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
| `byPk(value)` | `Relation` | `where(primary_key, .eq, value)`. |
| `order(field, direction)` | `Relation` | Adds a sort key after those already set: `.order(.role, .asc).order(.age, .desc)` is `ORDER BY role ASC, age DESC`. At most `Query.max_orders = 4` keys; a fifth panics. |
| `reorder(.{ .{ field, direction }, ... })` | `Relation` | Replaces every sort key; `reorder(.{})` removes the order. More than `max_orders` keys is a compile error. |
| `limit(n)`, `offset(n)` | `Relation` | `n: usize`. |
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
| `combine(.assoc, target)` | `zom.Combined(...)` | This relation with association `assoc` of its schema, read from `target`, a relation over the association's target schema. Lazy; its `mapTo(E, allocator)` and `mapWith(M, allocator)` return a `zom.CombineResult(E)`. See [Associations](#associations). |
| `join(.assoc)` | `Relation` | The rows that have at least one row of association `assoc`, each once, as the same relation type. Needs `supports.join` (a compile error otherwise, even on a `.fallback` relation). See [Join](#join). |
| `whereJoined(.assoc, field, op, value)` | `Relation` | A filter on the joined rows, typed like `where` on the target's tuple. Needs `join(.assoc)` first. |
| `create(tuple)` | `Create` | `.map(f)` applies `f: fn (Tuple) Tuple`; `.associate(.assoc, parent)` overwrites the tuple's foreign key from `parent`; `.commit()` returns `!Tuple`, the stored tuple. `.commitAlloc(allocator)` does the same on every adapter, allocating the returned strings when they are caller-owned (zom-pg, where plain `commit()` is a compile error); free the result with `freeOne`. A compile error after `select`. |
| `createMany(tuples)` | `CreateMany` | A compile error after `select`. `tuples: []const Tuple`, borrowed until commit. `.commit()` returns `!usize`, the rows inserted. Uses the dataset's `insertMany`, else loops over `insert` (see [the adapter contract](#the-adapter-contract)). `.associate(.assoc, parent)` sets every tuple's foreign key on a copy, so the changeset then commits with `.commitAlloc(allocator)`. |
| `associate(.assoc, parent)` | `zom.changeset.Scoped(...)` | Sets the foreign key of `belongsTo` association `assoc` from `parent`, the target's tuple or a `select` of it that kept the key. Its `create(data)` and `createMany(rows)` take `Input`, the tuple without that key; chain `.associate` for more associations. Its `createMany` commits with `commitAlloc(allocator)`. A compile error after `select`. See [Associated creates](#associated-creates). |
| `update()` | `Update` | `.set(field, value)` adds a change (at most `max_changes = 16`); `.commit()` returns `!usize`, the rows changed. |
| `delete()` | `!usize` | The rows removed. |

On a `.fallback` relation, `update().commit()` and `delete()` return
`error.UnsupportedFilter` when the dataset can't evaluate every filter:
writes never run in memory. On a joined relation they return
`error.JoinedWrite`.

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

#### Query support: strict and fallback

A dataset says which query features it evaluates with `supports` and,
optionally, per attribute with `filterable` (see [the adapter
contract](#the-adapter-contract)). A relation is `.strict` by default:
building a query the dataset can't run is a compile error, at the call that
needs the missing feature, naming the adapter, the relation, the call and the
feature:

```
zom: adapter 'limited' cannot evaluate `where(.name, .eq, ...)` on relation 'items': its dataset's `filterable` rejects `.eq` on 'name'; call `allowFallback()` on the relation to evaluate it in memory instead
```

`where`, `whereIn`, `whereNotIn` and `whereAny` / `whereNot` (every
condition inside them too) check filters, `order` and `reorder` check sort
keys, and `offset` checks `supports.offset`. `select` and `limit` work on
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

`@TypeOf(self.rel)` lets a view return the relation's type without naming
it. The shortcuts still go to the relation itself (`rel`), not the wrapper.
`UserRepo.Relations`, `UserRepo.Root` (the root's wrapper or relation) and
`UserRepo.RootRelation` are the generated types.

A repository copies the container's relations (a dataset pointer and a
query each), so it is a cheap value; it must not be used after the
container's `deinit`. A relation the container lacks, a root that isn't in
`.relations`, a wrapper without a `rel` field of the right type, and a
relation named like one of the repository's own declarations (`create`,
`all`, ...) are compile errors.

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
dropped by `select` are compile errors. A target relation with a `limit` or
`offset` is `error.PagedCombineTarget`, since paging would apply to each
batched query rather than to each user.

The result is a tree of allocations, so `mapTo` returns a
`zom.CombineResult(Author)`: `items`, plus an arena owning every slice and
string in it, including the strings of a caller-owned adapter like zom-pg.
One `deinit()` frees it all.

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

A join needs `supports.join`. Without it, `join` and `whereJoined` are
compile errors on a `.fallback` relation too, since a join reads another
dataset and can't run in memory on this one's rows. zom-pg and the memory
gateway support it; csv and yaml do not. On zom-sql it compiles to

```sql
SELECT DISTINCT "users"."id", "users"."name", ... FROM "users"
INNER JOIN "posts" ON "posts"."user_id" = "users"."id"
WHERE "posts"."published" = $1 ORDER BY "users"."name" ASC
```

with every column qualified by its table. The memory gateway runs a hash
semi-join: the matching posts' keys go into a set, and a user is kept when
its key is in it, in O(users + posts).

A query holds one join: joining the same association again changes
nothing, and joining a second one panics, as does `whereJoined` without
the `join`. `update` and `delete` on a joined relation return
`error.JoinedWrite`, because which rows a join keeps depends on the other
table.

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

Nested combines (`users.combine(.posts.combine(.comments))`) are not
supported yet. Until they are, the deprecated `combineMany` can attach a
second level to slices already loaded, in O(n·m), with its keys taken from
the descriptor:
`.{ .into = "comments", .parent_key = comments.primary_key, .child_key = comments.foreign_key }`.

### Value

```zig
const big: zom.Value = .{ .uint = std.math.maxInt(u64) };
std.debug.assert(big.order(.{ .int = -1 }).? == .gt);
std.debug.assert(big.order(.{ .string = "x" }) == null); // different kinds never compare
std.debug.assert(zom.query.toValue(@as(u64, 7)).eql(.{ .int = 7 }));
```

`zom.Value` is a `union(enum)`:

| Variant | Holds |
|---|---|
| `null` | A `null` optional attribute. |
| `boolean: bool` | `bool`. |
| `int: i64` | Every integer type up to 64 bits, except `u64`. |
| `uint: u64` | `u64` (and `usize` on 64-bit targets), and integer literals above `maxInt(i64)`. |
| `float: f64` | Float types. |
| `string: []const u8` | Strings, and enum values (by tag name). |

`a.order(b)` returns `?std.math.Order`: numbers compare across `int`, `uint`
and `float`, strings compare bytewise, and values of different kinds return
`null`. `a.eql(b)` is `order == .eq`. Integers wider than 64 bits are a
compile error until `u128` support lands.

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
| `Gateway.transaction` | `fn (*Gateway, ...)` | no, `.transaction` | Not used by the core yet. |
| `read` | `fn (*Dataset, Q, Allocator) ![]S.Tuple` | yes | Applies filters, then order, then offset and limit. The caller frees the slice. |
| `count` | `fn (*Dataset, Q) !usize` | yes | The number of rows `read` would return: filters, offset and limit all apply. |
| `insert` | `fn (*Dataset, S.Tuple) !S.Tuple`, or `fn (*Dataset, S.Tuple, Allocator) !S.Tuple` | no, `.writable` | Returns the tuple as stored. `error.DuplicatePrimaryKey` on a key clash. With `strings = .caller` it must take the allocator, which owns the returned strings; `createMany` then needs `insertMany`. |
| `insertMany` | `fn (*Dataset, []const S.Tuple) !usize` | no, `.batch_insert` | Returns the tuples stored. `error.DuplicatePrimaryKey` on a key clash, with the stored rows or inside the batch. Used by `createMany`. |
| `update` | `fn (*Dataset, Q, []const Q.Change) !usize` | no, `.updatable` | Returns the rows changed. A failed update changes nothing. |
| `delete` | `fn (*Dataset, Q) !usize` | no, `.deletable` | Returns the rows removed. |
| `supports` | `zom.Supports` | no | The query features the dataset handles; the defaults when missing. A strict relation that uses one left out does not compile; see [Query support](#query-support-strict-and-fallback). |
| `filterable` | `fn (comptime field: []const u8, comptime op: zom.Op) bool` | no | Narrows `supports` per attribute, for a backend that only filters on some (TigerBeetle filters transfers on `ledger` and `code`, not `amount`). Called at compile time, only for ops `supports` allows; false makes that filter unsupported. Without it, every attribute is filterable. |
| `strings` | `zom.StringOwnership` | no | `.dataset` (the default): returned strings point into the dataset. `.caller`: `read`, `readProjected` and `insert` allocate them with the allocator passed in, and every string attribute must be a slice. |
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
default; `-Dpg=false` leaves zom-pg out.

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
only zom-pg's, and `zig build test` runs them all along with the core.
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
`error.UnboundedWrite` for a query with no filters, so a forgotten `where`
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

### Errors

| Error | Returned by |
|---|---|
| `error.DuplicatePrimaryKey` | `create(...).commit()`, `createMany(...).commit()`, or an update that sets the primary key to one already in use (or sets it on more than one row). |
| `error.ValueOutOfRange` | `update().set(...).commit()` with a runtime value that does not fit the attribute, e.g. a `u32` holding 300 set on a `u8`. |
| `error.MoreThanOneTuple` | `one`. |
| `error.DatasetTypeMismatch` | `memory.Gateway.dataset` (and so `Relation.init`), when two different schema types share a dataset name. |
| `error.UnboundedWrite` | zom-sql's `compileUpdate` and `compileDelete`, for a query with no filters and `all` not set. |
| `error.EmptyUpdate` | zom-sql's `compileUpdate`, with no changes. |
| `error.UnsupportedFilter` | `update().commit()` and `delete()` on a `.fallback` relation with a filter its dataset can't evaluate. |
| `error.JoinedWrite` | `update().commit()` and `delete()` on a relation with a `join`, and zom-sql's `compileUpdate` / `compileDelete` on a joined query. |
| `error.JoinUnavailable` | A join read on a `memory.Store` that no `memory.Gateway` handed out, so it has no other dataset to join. |
| `error.OutOfMemory` | Anything that takes or uses an allocator. |

`zom.adapter.Error` reserves the names every adapter uses for the same
condition (`DuplicatePrimaryKey`, `ValueOutOfRange`, `NotFound`, `ReadOnly`,
`ConnectionFailed`); its doc comments say when each one applies.

### Planned changes

These are scheduled in [plan.md](plan.md) and will each come with a version
bump and a changelog entry:

- Phase 6: `zom.Value` gains a `u128` variant.

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
