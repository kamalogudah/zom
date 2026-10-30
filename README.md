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
| **Adapter shape** | Adapters subclass `ROM::Gateway`, `ROM::Relation` and `ROM::Memory::Dataset`, then override methods. | No inheritance. A gateway is any type with the right declarations (see [the adapter contract](#the-adapter-contract)). File adapters will *wrap* the memory engine instead of subclassing it. *Planned: `zom.memory.Store(S)`.* |
| **Optional features** | Whether an adapter supports a command is found out at runtime, when the command is built or run. | An adapter simply leaves out `insert`, `update` or `delete`, and `relation.create(...).commit()` fails to compile with a message naming the adapter. `zom.Adapter(G).capabilities(S)` says what it supports. |
| **Checking an adapter** | `ROM::Lint` specs, run by each adapter gem. | `zom.lint`, a test suite each adapter runs in its own `zig build test`. *Planned.* |
| **Container** | `ROM.container` builds a runtime registry: `container.relations[:users]`. | Relations are types, so a container is a comptime struct with one field per relation: `app.relations.users`. A missing relation is a compile error, not a runtime lookup failure. *Planned: `zom.Container`.* |
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
| `zom.Adapter(G)` | Checks gateway `G` against the [adapter contract](#the-adapter-contract), reporting every problem in one compile error. Has `Gateway`, `name` (`G.adapter_name`), `Dataset(S)` (checks the dataset for schema `S`), `capabilities(S) Capabilities`, `has(S, cap) bool` and `require(S, cap, method)`. |
| `zom.Capability` | `writable`, `batch_insert`, `updatable`, `deletable`, `transaction`. |
| `zom.Capabilities` | A struct with one `bool` per `Capability`, all `false` by default. |
| `zom.adapter` | The module behind `Adapter`, `Capability` and `Capabilities`. |
| `zom.Query(T)` | The adapter-neutral query a relation builds: `filters` (AND-ed, at most `max_filters = 16`), `order: ?Order`, `limit: ?usize`, `offset: usize`. Adapters read it through `filterSlice()`, and may use `matches(row)`, `lessThan(order, a, b)` and `fieldValue(row, field)` to evaluate it in memory. Nested types: `Field` (enum of `T`'s fields), `Filter`, `Order`, `Change`. |
| `zom.Value` | The runtime value carried by filters and changes. See [Value](#value). |
| `zom.Op` | Filter operators: `eq`, `neq`, `lt`, `lte`, `gt`, `gte`. `op.sql()` returns the SQL spelling. |
| `zom.Direction` | `asc`, `desc`. |
| `zom.changeset` | `Create(Rel)` and `Update(Rel)`, the types returned by `relation.create` and `relation.update`. You don't name them yourself. |
| `zom.Mapper(Src, Dst, .{ .renames })` | A comptime mapper: `call(src) Dst` and `many(allocator, srcs) ![]Dst`. A `Dst` field takes the `Src` field of the same name (or its rename), else its default; neither is a compile error. |
| `zom.combineMany(.{ .into, .parent_key, .child_key }, allocator, parents, children)` | Sets `parent.into` to the children whose `child_key` equals the parent's `parent_key`. O(n·m). |
| `zom.mapper` | The module behind `Mapper` and `combineMany`, with their option types `Options`, `Rename` and `CombineOptions`. |
| `zom.memory` | The in-memory adapter: `Gateway` (`adapter_name = "memory"`, `Config = struct {}`, `init(allocator, Config)`, `deinit()`) and `MemoryDataset(S)`. Every capability except `transaction`. |
| `zom.sql` | `compileSelect(T, allocator, table, query) !Compiled`, returning `Compiled{ sql, params }` with Postgres placeholders (`$1`). `writeIdent` appends a quoted identifier. |
| `zom.query` | The module behind `Query`, `Value`, `Op` and `Direction`. Adapters can use `toValue(x) Value` and `fromValue(F, value) !F` to convert between attribute values and `Value`. Its `assert*`, `isString` and `isComptimeOnly` helpers are used by the core and are not part of the frozen API. |

### Relation

`users` below is a `zom.Relation(S, Gateway)`. Building methods return a new
relation and never touch the dataset. `field` is always an enum literal, and
`value` is type-checked against the attribute at compile time.

| Method | Returns | Notes |
|---|---|---|
| `Relation.init(*Gateway)` | `!Relation` | Asks the gateway for the schema's dataset. |
| `where(field, op, value)` | `Relation` | Filters are AND-ed. `null` means `IS NULL` (`eq`) or `IS NOT NULL` (`neq`). |
| `byPk(value)` | `Relation` | `where(primary_key, .eq, value)`. |
| `order(field, direction)` | `Relation` | One order; a second call replaces it. |
| `limit(n)`, `offset(n)` | `Relation` | `n: usize`. |
| `toSlice(allocator)` | `![]Tuple` | Caller frees. |
| `one(allocator)` | `!?Tuple` | `null` when empty, `error.MoreThanOneTuple` when ambiguous. |
| `first(allocator)` | `!?Tuple` | |
| `count()` | `!usize` | |
| `mapTo(E, allocator)` | `![]E` | `mapWith(zom.Mapper(Tuple, E, .{}))`. |
| `mapWith(M, allocator)` | `![]M.Output` | `M` is a `zom.Mapper`. |
| `create(tuple)` | `Create` | `.map(f)` applies `f: fn (Tuple) Tuple`; `.commit()` returns `!Tuple`, the stored tuple. |
| `update()` | `Update` | `.set(field, value)` adds a change (at most `max_changes = 16`); `.commit()` returns `!usize`, the rows changed. |
| `delete()` | `!usize` | The rows removed. |

The relation's fields `dataset` and `query` are public too, so a relation
can be handed to an adapter function such as `zom.sql.compileSelect`.

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
| `count` | `fn (*Dataset, Q) !usize` | yes | Applies filters only. |
| `insert` | `fn (*Dataset, S.Tuple) !S.Tuple` | no, `.writable` | Returns the tuple as stored. `error.DuplicatePrimaryKey` on a key clash. |
| `insertMany` | `fn (*Dataset, []const S.Tuple) !usize` | no, `.batch_insert` | Returns the tuples stored. Not used by the core yet. |
| `update` | `fn (*Dataset, Q, []const Q.Change) !usize` | no, `.updatable` | Returns the rows changed. A failed update changes nothing. |
| `delete` | `fn (*Dataset, Q) !usize` | no, `.deletable` | Returns the rows removed. |

A method may take `self` by value, `*Self` or `*const Self`. Every dataset
call is fallible, so an adapter's own errors (I/O, connection loss) flow
through `try`. Without `.writable`, `.updatable` or `.deletable`, the matching
`create(...).commit()`, `update().commit()` or `delete()` is a compile error
naming the adapter:

```
zom: adapter 'csv' is not .writable, so `create` is not available on users (its dataset has no `insert`)
```

### Errors

| Error | Returned by |
|---|---|
| `error.DuplicatePrimaryKey` | `create(...).commit()`, or an update that sets the primary key to one already in use (or sets it on more than one row). |
| `error.ValueOutOfRange` | `update().set(...).commit()` with a runtime value that does not fit the attribute, e.g. a `u32` holding 300 set on a `u8`. |
| `error.MoreThanOneTuple` | `one`. |
| `error.DatasetTypeMismatch` | `memory.Gateway.dataset` (and so `Relation.init`), when two different schema types share a dataset name. |
| `error.InvalidNullComparison` | `sql.compileSelect`, for `lt`/`lte`/`gt`/`gte` against `null`. |
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
- A relation does not copy the values you filter on. A string passed to
  `where` must stay alive until the relation is last used.
- The gateway must outlive every relation made from it, and
  `memory.Gateway.deinit` frees all of its datasets at once.
- For `combineMany`, use an arena: it allocates one child slice per parent.

## Memory adapter semantics

- The primary key is unique: `create` or `update().set(.id, ...)` returns
  `error.DuplicatePrimaryKey` instead of storing a second row with that key.
- An update checks every change before writing, so a rejected update leaves
  every row as it was.
- `order` sorts nulls the way Postgres does: last on `.asc`, first on `.desc`.
- `count` and `delete` return `!usize` like every other dataset call, because
  real adapters do I/O for them. The memory adapter never fails, but callers
  still write `try users.count()`.

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
| `src/relation.zig` | `Relation(S, Gateway)`: immutable query builder | Comptime field enums, `anytype` |
| `src/changeset.zig` | `Create` and `Update` changesets | Fixed-capacity arrays |
| `src/mapper.zig` | Copies tuples into domain structs | `inline for` over struct fields |
| `src/adapters/memory.zig` | In-memory gateway and dataset | Allocators, arenas, `ArrayList`, hash maps, type erasure with `*anyopaque` |
| `src/adapters/sql.zig` | Compiles a query to a SQL string | Building strings with `ArrayList(u8)` |
| `src/tests/` | Tests, one file per layer, with shared `fixtures.zig` | `std.testing` |
| `examples/readme.zig` | Every README code block, compiled by `zig build test` | Using zom as a package import |
| `tests/compile_errors/` | Code that must *not* compile, checked by `zig build compile-errors` | What `@compileError` messages users see |

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
