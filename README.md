# zom

A [rom-rb](https://github.com/hanakai-rb/rom) style data mapping toolkit for Zig 0.16.

rom's core idea carries over directly: persistence is split into small layers
that each do one thing, and nothing is an "active record".

| ROM (Ruby)                                 | zom                                                            |
|--------------------------------------------|----------------------------------------------------------------|
| `ROM::Gateway` / adapter                   | `zom.memory.Gateway` (any type that passes `zom.Adapter`)      |
| dataset                                    | `Gateway.Dataset(Schema)`: `read`, `count`, and optionally `insert`, `insertMany`, `update`, `delete` |
| `schema(:users) do attribute ... end`      | `zom.Schema(UserTuple, "users", .id)`                          |
| `ROM::Relation`                            | `zom.Relation(Schema, Gateway)`, an immutable value             |
| `users.where(...).order(...).limit(...)`   | `users.where(.age, .gt, 25).order(.name, .asc).limit(10)`      |
| `users.by_pk(1).one`                       | `users.byPk(1).one(allocator)`                                 |
| `users.changeset(:create, data).commit`    | `users.create(tuple).map(f).commit()`                          |
| `users.changeset(:create, [a, b]).commit`  | `users.createMany(&.{ a, b }).commit()`                        |
| `users.by_pk(1).changeset(:update, ...)`   | `users.byPk(1).update().set(.email, "...").commit()`           |
| `command(:delete)`                         | `try users.where(...).delete()`                                |
| `ROM::Mapper`, `map_with`, `map_to`        | `zom.Mapper(Tuple, Entity, .{ .renames = ... })`, `mapWith`, `mapTo` |
| `users.combine(:posts)`                    | `zom.combineMany(.{ .into, .parent_key, .child_key }, ...)`    |
| rom-sql (Sequel)                           | `zom.sql.compileSelect`, a query-to-SQL compiler with no driver yet |

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
  relation can be evaluated in memory or compiled to SQL (see the last test).

## How zom differs from rom

rom is built on Ruby's runtime: classes register themselves, adapters
subclass base classes, and anything missing shows up as an exception when the
code runs. Zig has none of that, so zom does the same jobs at compile time.
Each row below says whether that part exists today or is planned (see
[plan.md](plan.md)).

| | rom (Ruby) | zom (Zig) |
|---|---|---|
| **Adapter registry** | `ROM.register_adapter(:csv, ROM::CSV)` puts the adapter in a global runtime table, and `ROM.container(:csv, path)` finds it there by symbol. | Zig has no runtime registry, and zom doesn't need one. An adapter is a Zig package that exports a `Gateway` type, and you pass that type in directly: `zom.Relation(Schema, zom_csv.Gateway)`. The contract is checked when the code compiles, not when it runs. *Today: `zom.Adapter` checks it, for `zom.memory` or any gateway you write. Planned: separate adapter packages.* |
| **Adapter shape** | Adapters subclass `ROM::Gateway`, `ROM::Relation` and `ROM::Memory::Dataset`, then override methods. | No inheritance. A gateway is any type with the right declarations (see [the adapter contract](#the-adapter-contract)). File adapters *wrap* the memory engine, `zom.memory.Store(S)`, instead of subclassing it. |
| **Optional features** | Whether an adapter supports a command is found out at runtime, when the command is built or run. | An adapter simply leaves out `insert`, `update` or `delete`, and `relation.create(...).commit()` fails to compile with a message naming the adapter. `zom.Adapter(G).capabilities(S)` says what it supports. |
| **Checking an adapter** | `ROM::Lint` specs, run by each adapter gem. | `zom.lint.run(Gateway, Factory)`, a test suite each adapter runs in its own `zig build test`. *Today: read, filter, null, ordering, limit/offset, `one`, insert, `insertMany`, update and delete checks.* |
| **Container** | `ROM.container` builds a runtime registry: `container.relations[:users]`. | Relations are types, so a container is a comptime struct with one field per relation: `app.relations.users`. A missing relation is a compile error, not a runtime lookup failure. *Today: `zom.Container`.* |
| **Schema inference** | rom-sql can read a table's columns from the database at boot. | A Zig struct has to exist when the code compiles, before any database is reachable, so you write the schema struct yourself. The plan adds a startup check against the database, and later a code generator. |
| **Structs** | `ROM::Struct` builds result classes at runtime from the schema. | You declare the entity struct (or use the tuple), and `mapTo` copies fields by name. Narrowed types, like a future `select(.{ .id, .name })`, are built at compile time with `@Struct`. |
| **Type errors** | Found at runtime, if the database or a type check catches them. | Found at compile time: wrong field names, wrong value types, `null` on a non-optional field, an enum value that doesn't exist, an integer literal that doesn't fit. |
| **Errors** | Exceptions. | Error sets: `error.DuplicatePrimaryKey`, `error.ValueOutOfRange`, `error.MoreThanOneTuple`, returned with `try`. |
| **Memory** | Garbage collected. | Every call that returns a slice takes an allocator, and the caller frees the slice (see [Memory rules](#memory-rules)). |
| **Transformations** | Changeset `map { ... }` takes a block, which can capture variables. | `map` takes a comptime function, `fn (Tuple) Tuple`. Zig has no closures, so anything it needs has to be in the tuple. |
| **Limits** | Queries grow as needed. | Filters and changes are capped at 16 each, with asserts, so building a query never allocates. |

## Usage

```zig
const zom = @import("zom");

const User = struct { id: u32, name: []const u8, age: u8, deleted_at: ?i64 = null };
const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

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
const Post = struct { id: u32, user_id: u32, title: []const u8 };
const Author = struct { id: u32, full_name: []const u8, posts: []const Post = &.{} };
const Posts = zom.Relation(zom.Schema(Post, "posts", .id), zom.memory.Gateway);
const AuthorMapper = zom.Mapper(User, Author, .{
    .renames = &.{.{ .from = "name", .to = "full_name" }},
});

const posts = try Posts.init(&gw);
_ = try posts.create(.{ .id = 10, .user_id = 1, .title = "Relations are values" }).commit();

// Updates and deletes target whatever the relation selects.
const changed = try users.byPk(1).update().set(.age, 32).commit(); // 1
const removed = try users.where(.age, .gt, 100).delete(); // 0

// Tuples become entities, then children are attached. combineMany
// allocates one slice per parent, so give it an arena.
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const authors = try users.mapWith(AuthorMapper, arena.allocator());
try zom.combineMany(
    .{ .into = "posts", .parent_key = "id", .child_key = "user_id" },
    arena.allocator(),
    authors,
    try posts.toSlice(arena.allocator()),
);

// The same relation compiles to SQL instead.
const compiled = try zom.sql.compileSelect(User, allocator, "users", users.where(.age, .gte, 18).query);
defer compiled.deinit(allocator);
// compiled.sql: SELECT "id", "name", "age", "deleted_at" FROM "users" WHERE "age" >= $1
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
| `zom.Schema(T, name, pk)` | Returns a schema type with `Tuple = T`, `name` (the dataset name) and `primary_key` (a field of `T`, as an enum literal). |
| `zom.Relation(S, Gateway)` | Returns an immutable relation type over schema `S` and an adapter's `Gateway`. Checks the [adapter contract](#the-adapter-contract) at compile time through `zom.Adapter(Gateway)`, which it exposes as `Relation.Adapter`. |
| `zom.Adapter(G)` | Checks gateway `G` against the [adapter contract](#the-adapter-contract), reporting every problem in one compile error. Has `Gateway`, `name` (`G.adapter_name`), `Dataset(S)` (checks the dataset for schema `S`), `capabilities(S) Capabilities`, `has(S, cap) bool`, `readOnly(S) bool` and `require(S, cap, method)`. |
| `zom.Capability` | `writable`, `batch_insert`, `updatable`, `deletable`, `transaction`. |
| `zom.Capabilities` | A struct with one `bool` per `Capability`, all `false` by default. |
| `zom.adapter` | The module behind `Adapter`, `Capability` and `Capabilities`. |
| `zom.Query(T)` | The adapter-neutral query a relation builds: a filter tree, `order: ?Order`, `limit: ?usize`, `offset: usize`. The tree is stored flat so a copy is a full copy: `filters` (at most `max_filters = 16`) and `nodes` (at most `max_nodes = 32`: filters plus `any` / `all` / `not` groups, which refer to children by index), AND-ed at the top level. An adapter without `or` support reads an AND-only query through `filterSlice()` (it asserts `isConjunction()`); one with it walks `nodeSlice()` from `topNodes()`. `matches(row)` and `truth(row) ?bool` evaluate the query in memory with SQL's three-valued logic, alongside `lessThan(order, a, b)` and `fieldValue(row, field)`. Nested types: `Field` (enum of `T`'s fields), `Filter` (`field`, `op`, `operand`), `Node` (`filter`, `and_group`, `or_group`, `not`), `Children`, `Order`, `Change`. `max_in = 64` bounds one `in` list. The query also builds itself, with the same `where` / `whereIn` / `whereNotIn` / `whereAny` / `whereNot` as a relation, so adapters and tests can make one without a gateway. |
| `zom.any(conds)`, `zom.all(conds)`, `zom.not(cond)` | Boolean groups to nest inside `whereAny` / `whereNot`. A condition is `.{ field, op, value }` or another group. |
| `zom.Value` | The runtime value carried by filters and changes. See [Value](#value). |
| `zom.Op` | Filter operators: `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `in`, `not_in`, `like`, `ilike`, `between`, `is_null`, `is_not_null`. `op.sql()` returns the SQL spelling, `op.operand()` the `Operand` variant it takes. |
| `zom.Direction` | `asc`, `desc`. |
| `zom.Container(spec)` | Declares gateways and relations once; `init(self, allocator, Config)` / `deinit()` connect and disconnect them all. See [Container](#container). |
| `zom.changeset` | `Create(Rel)`, `CreateMany(Rel)` and `Update(Rel)`, the types returned by `relation.create`, `relation.createMany` and `relation.update`. You don't name them yourself. |
| `zom.Mapper(Src, Dst, .{ .renames })` | A comptime mapper: `call(src) Dst` and `many(allocator, srcs) ![]Dst`. A `Dst` field takes the `Src` field of the same name (or its rename), else its default; neither is a compile error. |
| `zom.combineMany(.{ .into, .parent_key, .child_key }, allocator, parents, children)` | Sets `parent.into` to the children whose `child_key` equals the parent's `parent_key`. O(n·m). |
| `zom.mapper` | The module behind `Mapper` and `combineMany`, with their option types `Options`, `Rename` and `CombineOptions`. |
| `zom.codec` | Text cells to field values, for adapters whose rows arrive as strings. `decodeField(F, text, opts) !F` decodes one cell, and `decodeRow(T, cells, opts, ?*Diagnostic) !T` decodes a row, in field order or through `Options.columns`. `Options.null_text` (default `""`) means null. Strings borrow the cells. On error the `Diagnostic` has `row`, `column`, `field`, `text` and `err`, and formats with `{f}` as `14:3 (age): "abc" is not an integer from 0 to 255`. The other way, `encodeField(writer, value, opts)` and `encodeRow(writer, T, row, opts, sep)` write values back so they decode to the same thing: ints `{d}`, floats in their shortest round-trip form (decimal, or scientific outside `1e-6`..`1e21`), `true`/`false`, tag names, strings as they are, `null` as `null_text`. Nothing is quoted; that is the format writer's job. The accepted spellings are listed in `src/codec.zig`. |
| `zom.memory` | The in-memory adapter: `Gateway` (`adapter_name = "memory"`, `Config = struct {}`, `init(allocator, Config)`, `deinit()`), whose dataset is `Store(S)`. Every capability except `transaction`. |
| `zom.memory.Store(S)` | The in-memory row engine, usable without a gateway: `init(allocator)`, `deinit()`, `read`, `count`, `insert`, `insertMany`, `update`, `delete`, plus `rows() []const Tuple` (every row, in insertion order), `load(row)` and `loadMany(rows)` (insert without the primary-key check, for trusted bulk loads) and `clear()`. Strings are copied into the store's arena; rows it returns point into it until `clear` or `deinit`. |
| `zom.lint` | The adapter conformance suite, see [Checking an adapter](#checking-an-adapter-with-zomlint). Also exports the schema it tests on, `Users` (`User`, `Role`), its seed rows, `users`, `OnDuplicate` and `expectSharedError`. |
| `zom.sql` | `compileSelect(T, allocator, table, query) !Compiled`, returning `Compiled{ sql, params }` with Postgres placeholders (`$1`). `writeIdent` appends a quoted identifier. |
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
| `order(field, direction)` | `Relation` | One order; a second call replaces it. |
| `limit(n)`, `offset(n)` | `Relation` | `n: usize`. |
| `toSlice(allocator)` | `![]Tuple` | Caller frees. |
| `one(allocator)` | `!?Tuple` | `null` when empty, `error.MoreThanOneTuple` when ambiguous. |
| `first(allocator)` | `!?Tuple` | |
| `count()` | `!usize` | The number of rows `toSlice` would return, so `limit` and `offset` apply. |
| `mapTo(E, allocator)` | `![]E` | `mapWith(zom.Mapper(Tuple, E, .{}))`. |
| `mapWith(M, allocator)` | `![]M.Output` | `M` is a `zom.Mapper`. |
| `create(tuple)` | `Create` | `.map(f)` applies `f: fn (Tuple) Tuple`; `.commit()` returns `!Tuple`, the stored tuple. |
| `createMany(tuples)` | `CreateMany` | `tuples: []const Tuple`, borrowed until commit. `.commit()` returns `!usize`, the rows inserted. Uses the dataset's `insertMany`, else loops over `insert` (see [the adapter contract](#the-adapter-contract)). |
| `update()` | `Update` | `.set(field, value)` adds a change (at most `max_changes = 16`); `.commit()` returns `!usize`, the rows changed. |
| `delete()` | `!usize` | The rows removed. |

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
can be handed to an adapter function such as `zom.sql.compileSelect`.

### Container

`zom.Container(spec)` declares the gateways and the relations over them in
one place, like `ROM.container`. Each relation names its gateway with an enum
literal:

```zig
const UserSchema = zom.Schema(User, "users", .id);
const PostSchema = zom.Schema(Post, "posts", .id);

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

A relation that names a gateway the container doesn't have, a relation that
isn't `.{ Schema, .gateway }`, and a gateway that fails `zom.Adapter` are all
compile errors.

[examples/csv_users](examples/csv_users/src/main.zig) puts two adapters in
one container: users read from `data/users.csv` through `zom_csv.Gateway`,
posts held in `zom.memory.Gateway`, joined with `zom.combineMany`. Run it
with `cd examples/csv_users && zig build run`; `zig build test` at the root
runs it too and checks its output.

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
| `insert` | `fn (*Dataset, S.Tuple) !S.Tuple` | no, `.writable` | Returns the tuple as stored. `error.DuplicatePrimaryKey` on a key clash. |
| `insertMany` | `fn (*Dataset, []const S.Tuple) !usize` | no, `.batch_insert` | Returns the tuples stored. `error.DuplicatePrimaryKey` on a key clash, with the stored rows or inside the batch. Used by `createMany`. |
| `update` | `fn (*Dataset, Q, []const Q.Change) !usize` | no, `.updatable` | Returns the rows changed. A failed update changes nothing. |
| `delete` | `fn (*Dataset, Q) !usize` | no, `.deletable` | Returns the rows removed. |

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
ordering (nulls last on `.asc`, first on `.desc`), `limit` and `offset` edge
cases, and `one`; every case also checks that `count` equals the rows read.
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

Adapters are separate Zig packages, like rom-csv next to rom-core. Until they
move to their own repos they live in `adapters/<name>/`, and each one depends
on zom by path, so splitting one out later only changes that path into a
`.url` and `.hash`:

```
adapters/csv/
├── build.zig.zon   .name = .zom_csv, its own .fingerprint, .zom = .{ .path = "../.." }
├── build.zig       b.dependency("zom", ...).module("zom"), a zom_csv module, a test step
└── src/root.zig    pub const Gateway = struct { pub const adapter_name = "csv"; ... }
```

`adapters/csv` is the template: copy it, rename the package (`.name =
.zom_yaml`), delete the `.fingerprint` line and run `zig build` once, which
fails and prints a fresh fingerprint to paste in. Every package needs its own.
A file adapter (one that loads files into `zom.memory.Store`) doesn't write
a gateway at all. It writes a `Format` with `load` and `dump`, and
`zom.file.Gateway(Format, .read_only)` / `.writable` supply the rest:
finding the file, loading each dataset once, the read-only and writable
dataset types, and the atomic `sync`. zom-csv and zom-yaml are both built
this way. The contract is listed in `src/file.zig` and checked with
`@hasDecl` when the gateway type is built.

An application depends on `zom` plus the adapters it uses, and
`@import("zom")` and `@import("zom_csv")` are the only imports it needs: the
gateway is `zom_csv.Gateway`, passed to `zom.Relation` like any other.

To work on an adapter, run its tests from its own directory:

```sh
cd adapters/csv && zig build test
```

From the repo root, `zig build test-adapters` does that for every adapter, and
`zig build test` runs it too. A new adapter must be added to `adapter_dirs` in
the root `build.zig`. `adapters/` is not in zom's `.paths`, so changing an
adapter never changes zom's package hash. Every adapter's tests should call
`zom.lint.run` once it can store the lint seed rows.

### Errors

| Error | Returned by |
|---|---|
| `error.DuplicatePrimaryKey` | `create(...).commit()`, `createMany(...).commit()`, or an update that sets the primary key to one already in use (or sets it on more than one row). |
| `error.ValueOutOfRange` | `update().set(...).commit()` with a runtime value that does not fit the attribute, e.g. a `u32` holding 300 set on a `u8`. |
| `error.MoreThanOneTuple` | `one`. |
| `error.DatasetTypeMismatch` | `memory.Gateway.dataset` (and so `Relation.init`), when two different schema types share a dataset name. |
| `error.InvalidNullComparison` | `sql.compileSelect`, for `lt`/`lte`/`gt`/`gte` against `null`. |
| `error.UnsupportedFilter` | `sql.compileSelect`, for `in`, `not_in`, `like`, `ilike` and `between`, which zom-sql will render with a `Dialect` (#35). |
| `error.OutOfMemory` | Anything that takes or uses an allocator. |

`zom.adapter.Error` reserves the names every adapter uses for the same
condition (`DuplicatePrimaryKey`, `ValueOutOfRange`, `NotFound`, `ReadOnly`,
`ConnectionFailed`); its doc comments say when each one applies.

### Planned changes

These are scheduled in [plan.md](plan.md) and will each come with a version
bump and a changelog entry:

- Phase 3: `zom.sql` moves out of the core into the `zom-sql` package.
- Phase 4: `zom.combineMany` is deprecated in favour of `combine`.
- Phase 6: `zom.Value` gains a `u128` variant.

## Memory rules

- `toSlice`, `mapTo`, `mapWith` and `Mapper.many` return slices the caller
  owns. `sql.compileSelect` returns a `Compiled` that the caller frees with
  `compiled.deinit(allocator)`.
- String attributes are copied into the dataset's arena on insert and update,
  so input buffers can be reused straight away. Strings you read back
  (including those in tuples from `one`, `first` and `create(...).commit()`)
  are valid for as long as the gateway lives.
- `createMany` does not copy the slice you pass; keep it alive until
  `commit`. The tuples' strings are copied on commit, as with `create`.
- A relation does not copy the values you filter on. A string passed to
  `where`, and the slice passed to `whereIn` / `whereNotIn`, must stay alive
  and unchanged until the relation (and every relation chained from it) is
  last used. A tuple given to `where(.x, .in, .{ ... })` has no such limit:
  its values are comptime-known and stored statically.
- The gateway must outlive every relation made from it, and
  `memory.Gateway.deinit` frees all of its datasets at once.
- For `combineMany`, use an arena: it allocates one child slice per parent.

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
- `count` and `delete` return `!usize` like every other dataset call, because
  real adapters do I/O for them. The memory adapter never fails, but callers
  still write `try users.count()`.
- `count` applies `limit` and `offset`, so it always equals the length of
  `toSlice`. `update` and `delete` ignore them for now.
- It passes `zom.lint`.

## Roadmap

[plan.md](plan.md) lays out the path from this toolkit to a core with
separate adapter packages, the way rom-core pairs with rom-sql, rom-csv and
rom-yaml:

0. Tidy the core and freeze the API as v0.2. *Done in 0.2.0.*
1. Adapter contract, `zom.lint` conformance suite, and `zom.Container`.
2. `zom-csv` and `zom-yaml`, built on the memory engine.
3. `zom-sql` compiler and the `zom-pg` driver on `karlseguin/pg.zig`,
   with projections and a richer query AST.
4. Associations in the schema, and `combine` with one `IN (...)` query
   instead of today's O(n·m) `combineMany`.
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
| `src/relation.zig` | `Relation(S, Gateway)`: immutable query builder | Comptime field enums, `anytype` |
| `src/container.zig` | `Container(spec)`: gateways and relations declared once, init/deinit in one place | Building struct types with `@Struct`, `errdefer` with a counter in an `inline for` |
| `src/changeset.zig` | `Create`, `CreateMany` and `Update` changesets | Fixed-capacity arrays, slices, comptime capability branching |
| `src/mapper.zig` | Copies tuples into domain structs | `inline for` over struct fields |
| `src/codec.zig` | Text cells to typed fields and back, with a `Diagnostic` out-parameter | `@typeInfo` dispatch, mapping error sets with `catch \|e\| switch`, the diagnostics pattern, `std.Io.Writer` and shortest round-trip float formatting |
| `src/adapters/memory.zig` | In-memory gateway and dataset | Allocators, arenas, `ArrayList`, hash maps, type erasure with `*anyopaque` |
| `src/adapters/sql.zig` | Compiles a query to a SQL string | Building strings with `ArrayList(u8)` |
| `src/tests/` | Tests, one file per layer, with shared `fixtures.zig` | `std.testing` |
| `examples/readme.zig` | Every README code block, compiled by `zig build test` | Using zom as a package import |
| `examples/csv_users/` | A program joining CSV users with in-memory posts through `zom.Container`, run and checked by `zig build test` | `b.addExecutable`, `pub fn main(init: std.process.Init)`, writing to stdout |
| `tests/compile_errors/` | Code that must *not* compile, checked by `zig build compile-errors` | What `@compileError` messages users see |
| `src/file.zig` | `zom.file`: the gateway and datasets file adapters share, over a `Format` (load and dump) | Comptime-parameterised generics, duck typing checked with `@hasDecl`/`@hasField`, atomic writes (temp file, fsync, rename) |
| `adapters/csv/` | The `zom-csv` package, a CSV `Format` for `zom.file`, depending on zom by path | `build.zig.zon` dependencies, `b.dependency(...).module(...)` |
| `adapters/yaml/` | The `zom-yaml` package: a YAML-subset parser and writer, and a YAML `Format` for `zom.file` | A hand-written line parser, arenas, escaping that round-trips |

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
const Users = zom.Relation(zom.Schema(User, "users", .id), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.where(.age, .eq, null);
}
```

`zig build compile-errors` (also run by `zig build test`) compiles every case and fails if one compiles, or if its stderr doesn't contain the `// expect:` text. For a multi-line error, start the file with several `// expect:` lines (one per line of the message, without its indentation); each must appear in stderr, as in `adapter_missing_decls.zig`. To add a case, drop a new `.zig` file in the folder; `build.zig` picks it up. Put the illegal code inside an `export fn` so the compiler analyzes it, and copy the expected text from the real error (types declared in the case show up as `<file name>.<Type>`). To reproduce one by hand:

```sh
zig build-obj -fno-emit-bin --dep zom -Mroot=tests/compile_errors/null_on_non_optional.zig -Mzom=src/root.zig
```

### 5. Good first tickets

Look for the [`good first issue`](https://github.com/kamalogudah/zom/labels/good%20first%20issue) label in the **Phase 0** milestone. Those tickets fix real bugs in code under 300 lines long, and each one comes with a failing test you can write first.
