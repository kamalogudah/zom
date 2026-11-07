<p align="center">
  <img src="Zom%20Iguana%20Data%20Mapping%20Logo.png" alt="Zom Iguana Data Mapping" width="240">
</p>

# zom

A [rom-rb](https://github.com/hanakai-rb/rom) style data mapping toolkit for Zig 0.17.

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
| `posts.changeset(:create, data).associate(user)` | `posts.associate(.author, user).create(data).commit()` (see [Associated creates](docs/associations.md#associated-creates)) |
| `users.by_pk(1).changeset(:update, ...)`   | `users.byPk(1).update().set(.email, "...").commit()`           |
| `command(:delete)`                         | `try users.where(...).delete()`                                |
| `ROM::Mapper`, `map_with`, `map_to`        | `zom.Mapper(Tuple, Entity, .{ .renames = ... })`, `mapWith`, `mapTo` |
| `users.combine(:posts)`                    | `users.combine(.posts, posts).mapTo(Author, allocator)` (see [Combine](docs/associations.md#combine)) |
| `users.join(:posts).where(posts[:published] => true)` | `users.join(.posts).whereJoined(.posts, .published, .eq, true)` (see [Join](docs/associations.md#join)) |
| rom-sql (Sequel)                           | [zom-sql](adapters/sql/README.md) compiles relations to SQL, and [zom-pg](adapters/pg/README.md) and [zom-sqlite](adapters/sqlite/README.md) run them on Postgres and SQLite |

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
  relation can be evaluated in memory, read from CSV or YAML, compiled to SQL,
  or sent to TigerBeetle. An adapter that can't do something (say, `update`
  on a read-only gateway) is a compile error, not a runtime surprise.

[How zom differs from rom](docs/rom-comparison.md) goes through the rest,
part by part.

## Install

zom needs **Zig 0.17.1**. Add it to your project:

```sh
zig fetch --save git+https://github.com/kamalogudah/zom#v0.17.1
```

zom's version tracks Zig's: the `v0.17.x` tags build with Zig 0.17.1, and
the `v0.16.x` tags with Zig 0.16.0. Use `#main` for the latest unreleased
changes.

zom is one package with a module per adapter. Depend on it once and import
the modules you use:

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zom", dep.module("zom"));
exe.root_module.addImport("zom_csv", dep.module("zom_csv")); // also zom_yaml, zom_sql
```

zom-pg, zom-sqlite and zom-tigerbeetle pull in a third-party dependency,
so they are off unless you ask for them: `.pg = true` (fetches pg.zig),
`.sqlite = true` (fetches the SQLite amalgamation) or `.tigerbeetle = true`
(fetches TigerBeetle's C client).

## Quick start, in memory

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

Swap `zom.memory.Gateway` for another gateway type and the same code runs
against that store, as long as the gateway supports what you call (a
read-only CSV gateway turns `create` into a compile error). Every slice zom returns belongs to the caller; see
[Memory rules](docs/memory.md) for who frees what.

## Examples

Each one is a small application under [examples/](examples/README.md),
built and run with `zig build run` from its directory:

| Example | What it shows | Needs |
|---|---|---|
| [csv_users](examples/README.md#csv_users-csv-and-memory-side-by-side) | users from a CSV file and posts in memory, in one container | nothing |
| [pg_repo](examples/README.md#pg_repo-a-repository-and-transactions-on-postgres) | a repository, a custom view, and a sign-up rolled back in a transaction ([walkthrough](docs/postgres-walkthrough.md)) | Postgres |
| [double_entry](examples/README.md#double_entry-a-ledger-on-tigerbeetle) | double-entry bookkeeping with linked transfers | TigerBeetle |

## Adapters

| Adapter | Module | Store |
|---|---|---|
| memory | `zom.memory` | in-process; for tests and prototypes |
| [zom-csv](adapters/csv/README.md) | `zom_csv` | CSV files, read-only or writable with an atomic `sync()` |
| [zom-yaml](adapters/yaml/README.md) | `zom_yaml` | YAML files, read-only or writable |
| [zom-sql](adapters/sql/README.md) | `zom_sql` | not a gateway: compiles relations to SQL for a dialect |
| [zom-pg](adapters/pg/README.md) | `zom_pg` | PostgreSQL, with transactions, joins and schema generation |
| [zom-sqlite](adapters/sqlite/README.md) | `zom_sqlite` | SQLite, compiled in, with transactions and joins |
| [zom-tigerbeetle](adapters/tigerbeetle/README.md) | `zom_tigerbeetle` | TigerBeetle accounts and transfers |

[adapters/README.md](adapters/README.md) compares what each one supports.

## Documentation

| Page | Covers |
|---|---|
| [API reference](docs/api.md) | Every export: relations, projections, pagination, strict and fallback queries, `Value`, errors |
| [Containers, repositories and plugins](docs/containers.md) | `zom.Container`, `zom.Repository`, custom views, timestamps, instrumentation, writing a plugin |
| [Associations](docs/associations.md) | `hasMany` / `belongsTo`, views, `combine`, `join`, associated creates, nesting |
| [Memory rules](docs/memory.md) | Who owns returned slices and strings, and what must outlive what |
| [Writing and checking adapters](docs/adapters.md) | The adapter contract, `zom.lint`, file formats, memory adapter semantics |
| [Postgres walkthrough](docs/postgres-walkthrough.md) | examples/pg_repo line by line, and reading error return traces |
| [How zom differs from rom](docs/rom-comparison.md) | Registry, inheritance, capabilities, inference, errors, memory |
| [Roadmap](docs/roadmap.md) and [plan.md](plan.md) | Where zom is going |
| [CHANGELOG.md](CHANGELOG.md) | What changed in each version |

## Contributing

New contributors are welcome, including people who are new to Zig. Work is
tracked as [GitHub issues](https://github.com/kamalogudah/zom/issues), and
[docs/contributing.md](docs/contributing.md) covers setup, a tour of the
code, the Zig concepts zom relies on, and how we work.

```sh
git clone git@github.com:kamalogudah/zom.git && cd zom
zig build test          # core, adapters, compile-error cases, examples
```

The code blocks in this README and in `docs/` are compiled and run by
`zig build test`, from [examples/readme.zig](examples/readme.zig), so the
docs can't drift from the API. The Postgres walkthrough's come from
[examples/pg_repo](examples/pg_repo/src/main.zig), checked in zom-pg's CI.
