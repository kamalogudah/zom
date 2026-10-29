# zom

A [rom-rb](https://github.com/hanakai-rb/rom) style data mapping toolkit for Zig 0.16.

rom's core idea carries over directly: persistence is split into small layers
that each do one thing, and nothing is an "active record".

| ROM (Ruby)                                 | zom                                                            |
|--------------------------------------------|----------------------------------------------------------------|
| `ROM::Gateway` / adapter                   | `zom.memory.Gateway` (any type with `Dataset` + `dataset`)     |
| dataset                                    | `Gateway.Dataset(Schema)`: `read`, `count`, `insert`, `update`, `delete` |
| `schema(:users) do attribute ... end`      | `zom.Schema(UserTuple, "users", .id)`                          |
| `ROM::Relation`                            | `zom.Relation(Schema, Gateway)`, an immutable value             |
| `users.where(...).order(...).limit(...)`   | `users.where(.age, .gt, 25).order(.name, .asc).limit(10)`      |
| `users.by_pk(1).one`                       | `users.byPk(1).one(allocator)`                                 |
| `users.changeset(:create, data).commit`    | `users.create(tuple).map(f).commit()`                          |
| `users.by_pk(1).changeset(:update, ...)`   | `users.byPk(1).update().set(.email, "...").commit()`           |
| `command(:delete)`                         | `users.where(...).delete()`                                    |
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
| **Adapter registry** | `ROM.register_adapter(:csv, ROM::CSV)` puts the adapter in a global runtime table, and `ROM.container(:csv, path)` finds it there by symbol. | Zig has no runtime registry, and zom doesn't need one. An adapter is a Zig package that exports a `Gateway` type, and you pass that type in directly: `zom.Relation(Schema, zom_csv.Gateway)`. The contract is checked when the code compiles, not when it runs. *Today: the check exists, for `zom.memory`. Planned: separate adapter packages.* |
| **Adapter shape** | Adapters subclass `ROM::Gateway`, `ROM::Relation` and `ROM::Memory::Dataset`, then override methods. | No inheritance. A gateway is any type with the right declarations (`Dataset`, `dataset`, and `read`/`count`/`insert`/`update`/`delete` on the dataset). File adapters will *wrap* the memory engine instead of subclassing it. *Planned: `zom.memory.Store(S)`.* |
| **Optional features** | Whether an adapter supports a command is found out at runtime, when the command is built or run. | An adapter will simply leave out `insert`, `update` or `delete`, and `relation.create(...)` will fail to compile with a message naming the adapter. *Planned.* |
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

var gw = zom.memory.Gateway.init(allocator);
defer gw.deinit();
const users = try Users.init(&gw);

_ = try users.create(.{ .id = 1, .name = "Achieng", .age = 31 }).commit();

const active = try users.where(.deleted_at, .eq, null).order(.name, .asc).toSlice(allocator);
defer allocator.free(active);
```

Run the tests with `zig build test`.

## Memory rules

- `toSlice`, `mapTo` and `mapWith` return slices the caller owns.
- String attributes are copied into the dataset's arena on insert and update,
  so input buffers can be reused straight away. Strings you read back are
  valid for as long as the gateway lives.
- For `combineMany`, use an arena: it allocates one child slice per parent.

## Memory adapter semantics

- The primary key is unique: `create` or `update().set(.id, ...)` returns
  `error.DuplicatePrimaryKey` instead of storing a second row with that key.
- An update checks every change before writing, so a rejected update leaves
  every row as it was.
- `order` sorts nulls the way Postgres does: last on `.asc`, first on `.desc`.

## Roadmap

[plan.md](plan.md) lays out the path from this toolkit to a core with
separate adapter packages, the way rom-core pairs with rom-sql, rom-csv and
rom-yaml:

0. Tidy the core (open issues, `count` becomes fallible).
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

### 2. A tour of the code (about 1,100 lines)

| File | What it does | Read it for |
|---|---|---|
| `src/root.zig` | Public API: re-exports everything | How a Zig package exposes modules |
| `src/schema.zig` | `Schema(T, name, pk)` returns a type | Functions that return types (generics) |
| `src/query.zig` | `Value` union, `Query(T)`, filter matching, compile-time type checks | Tagged unions, `@typeInfo`, `@compileError` |
| `src/relation.zig` | `Relation(S, Gateway)`: immutable query builder | Comptime field enums, `anytype` |
| `src/changeset.zig` | `Create` and `Update` changesets | Fixed-capacity arrays |
| `src/mapper.zig` | Copies tuples into domain structs | `inline for` over struct fields |
| `src/adapters/memory.zig` | In-memory gateway and dataset | Allocators, arenas, `ArrayList`, hash maps, type erasure with `*anyopaque` |
| `src/adapters/sql.zig` | Compiles a query to a SQL string | Building strings with `ArrayList(u8)` |
| `src/tests.zig` | All the tests | `std.testing` |

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

### 5. Good first tickets

Look for the [`good first issue`](https://github.com/kamalogudah/zom/labels/good%20first%20issue) label in the **Phase 0** milestone. Those tickets fix real bugs in code under 300 lines long, and each one comes with a failing test you can write first.
