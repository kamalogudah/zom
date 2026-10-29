# zom plan: from toolkit to core + adapters

Goal: make zom work like [rom](https://github.com/hanakai-rb/rom). zom is the
core, and storage backends ship as separate packages, the way rom-core is
paired with [rom-sql](https://github.com/hanakai-rb/rom-sql),
[rom-csv](https://github.com/rom-rb/rom-csv) and
[rom-yaml](https://github.com/rom-rb/rom-yaml). The adapters planned here are
`zom-sql` (with Postgres and SQLite drivers), `zom-csv`, `zom-yaml` and
`zom-tigerbeetle`. Anyone should be able to write another.

---

## 1. Where zom is today

| Area | State |
|---|---|
| Schema | `Schema(Tuple, name, pk)`: a struct, a dataset name, and a primary key. No associations, no attribute metadata. |
| Query | `Query(T)`: AND-only filters (`eq neq lt lte gt gte`), one `order`, `limit`, `offset`. Fixed capacity of 16 filters. |
| Value | `null`, `boolean`, `int` (i64), `float`, `string`. No `u64`/`u128`, no timestamps, no bytes. |
| Relation | Immutable and lazy. `where/order/limit/offset/byPk`, `toSlice/one/first/count`, `mapTo/mapWith`, `create/update/delete`. |
| Changeset | `Create` (with `map` steps) and `Update` (`set`), committed explicitly. |
| Mapper | Copies fields by name, with renames. `combineMany` joins loaded slices in memory (O(n·m)). |
| Adapter seam | The contract is checked at compile time: `Gateway.Dataset(S)` and `dataset(S)`, plus `read count insert update delete` on the dataset. |
| Adapters | `memory` (full), with primary keys enforced. `sql.compileSelect` (SELECT only, Postgres placeholders, no driver). |
| Packaging | One package, `zom`, with all adapters inside it. |

Open issues from the last review, still to fix:
- A `u64` value above the `i64` maximum crashes in `toValue`.
- String types other than `[]const u8` are not copied on insert.
- Enums sort alphabetically, not in declaration order.
- An update can be left half-done if the arena runs out of memory.
- In the SQL compiler, large `LIMIT`/`OFFSET` values overflow the format buffer, and identifiers are not quoted.

## 2. What rom has, and how each part maps to zom

rom is a monorepo with three parts:

- **core**: relations, schemas, gateways, commands, mappers, associations, plugins, `ROM::Lint`, and the memory adapter.
- **changeset**: create, update and delete changesets, `map` pipes, and associated changesets.
- **repository**: repositories, a root relation, and sessions.

Adapters are separate gems that call `ROM.register_adapter(:csv, ROM::CSV)`
and subclass `ROM::Gateway`, `ROM::Relation` and the dataset classes. rom-csv
and rom-yaml are small (under 300 lines each). They load files into a
`ROM::Memory::Dataset`, reuse the memory relation and commands, and add file
I/O on top (`sync!` writes back for CSV). rom-csv is read-only by default.

Zig has no runtime class registry, and it doesn't need one:

| rom (runtime) | zom (comptime) |
|---|---|
| `register_adapter(:sql, ROM::SQL)` | An adapter is a Zig package that exports a `Gateway` type. You "register" it by passing that type in. `zom.Adapter(G)` checks it at compile time. |
| `ROM::Lint` specs | `zom.lint.run(Adapter, factory)`: a reusable test suite each adapter runs in its own `zig build test`. |
| `ROM.container(:sql, url) { config.register_relation ... }` | `zom.Container(.{ .gateways = ..., .relations = ... })`: a comptime type with runtime `init`/`deinit` for connections. |
| Subclassing `Memory::Dataset` | Composition: `zom.memory.Store(S)` is a reusable engine that file adapters wrap. |
| Optional adapter features | Capabilities are optional declarations checked with `@hasDecl`, and missing ones fail at compile time with a clear message. |

## 3. Target architecture

```
zom (core package)
├── schema      attributes, primary key, associations, attribute metadata
├── query       query AST (filters, boolean groups, IN, projection, order, page)
├── value       Value union (adds u64/u128, bytes, timestamp)
├── relation    immutable relation, views, combine, materializers
├── command     create/update/delete commands (batch-aware)
├── changeset   changesets + map pipes + associated changesets
├── mapper      structs, renames, nested combine output
├── repository  Repository(Root, .{ relations }) + transactions
├── container   wires gateways + relations; one place to init/deinit
├── adapter     the contract, capability detection, error-set conventions
├── lint        conformance test suite adapters import
├── memory      reference adapter + reusable Store(S) engine
└── codec       row decoding helpers: text → Value → field (for csv/yaml/sql)

zom-sql          dialect-agnostic SQL compiler (SELECT/INSERT/UPDATE/DELETE, joins)
├── zom-pg       driver binding on karlseguin/pg.zig
└── zom-sqlite   driver binding on a SQLite Zig wrapper (later)
zom-csv          file gateway over memory.Store, read-only by default, optional sync
zom-yaml         same pattern as csv, nested values
zom-tigerbeetle  accounts/transfers over the native Zig client; immutable, batched
```

### 3.1 The adapter contract (v1)

A gateway package exports:

```zig
pub const Gateway = struct {
    pub const adapter_name = "csv";                 // required: used in error messages
    pub const Config = struct { ... };              // required: what init takes
    pub fn init(allocator, Config) !Gateway;        // required
    pub fn deinit(*Gateway) void;                   // required
    pub fn Dataset(comptime S: type) type;          // required
    pub fn dataset(*Gateway, comptime S: type) !*Dataset(S); // required
    pub fn transaction(*Gateway, ctx, comptime f) !R; // optional capability
};
```

A dataset implements everything it can:

| Decl | Required? | Notes |
|---|---|---|
| `read(query, allocator) ![]T` | yes | |
| `count(query) !usize` | yes | Becomes fallible (I/O). |
| `insert(T) !T` | no, `writable` | A read-only adapter leaves it out, and `relation.create` gives a compile error naming the adapter. |
| `insertMany([]const T) !usize` | no, `batch_insert` | Falls back to a loop over `insert`. TigerBeetle wants this. |
| `update(query, changes) !usize` | no, `updatable` | TigerBeetle leaves it out (its records are immutable). |
| `delete(query) !usize` | no, `deletable` | |
| `pub const supports: zom.Supports` | no | Which query features the adapter can handle (`or`, `in`, `like`, `order_on`, `offset`, `projection`, `join`). |

**Query support.** When a relation uses a feature the adapter's `supports`
leaves out, zom does one of two things, chosen per relation:
- `.strict` (the default): compile error, e.g. `zom-tigerbeetle cannot filter transfers on 'amount'`.
- `.fallback`: the adapter evaluates the parts it supports, and zom filters the rest in memory with the existing `Query.matches`.

**Errors.** The contract uses inferred error sets (`!T`), so each adapter's
errors flow through. The core defines the shared names every adapter must use
for the same condition: `error.DuplicatePrimaryKey`, `error.ValueOutOfRange`,
`error.NotFound`, `error.ReadOnly`, `error.ConnectionFailed`. The lint suite
checks these.

### 3.2 Packaging

- The core stays in this repo as the `zom` package. Adapters start life in
  `adapters/<name>/`, each with its own `build.zig.zon` depending on zom
  through `.path = "../.."`, so they can be split into their own repos later
  without code changes.
- An application depends on `zom` plus the adapters it needs. `@import("zom")`
  and `@import("zom_csv")` are the only imports it needs.
- `zom.memory` stays in core, like `ROM::Memory`, because tests, the lint
  suite and the file adapters all build on it.
- `zom.sql.compileSelect` moves out to `zom-sql`, so core has no SQL in it.

## 4. Phases

Each phase ends with `zig build test` green, the README updated, and the
lint suite covering the new contract surface.

### Phase 0: tidy the core (small, do first)
- Fix the open issues in section 1 (`u64` handling, string copying, enum
  order, half-done updates, the SQL buffer and identifier quoting).
- Make `count` fallible in the contract now, before any adapter depends on it.
- Split `tests.zig` by layer (relation, changeset, mapper, memory).
- **Done when** the issue list is empty and the public API is frozen as v0.2.

### Phase 1: adapter contract, lint suite, container
- Add `src/adapter.zig` with `zom.Adapter(G)`. It replaces the ad-hoc
  `assertGateway`/`assertDataset` with one checker that reports every
  missing requirement at once, and it works out capabilities.
- Add `src/lint.zig` with `zom.lint.run(G, factory)`: a generic test suite,
  like `ROM::Lint`, run against a schema it defines. It checks
  read/count/insert/update/delete behavior, `null` semantics, ordering with
  nulls, primary-key errors and limit/offset edge cases. Memory is the first
  adapter to pass it.
- Make `Relation` respect capabilities: `create/update/delete` only compile
  when the dataset has them.
- Add `zom.Container`, which declares the gateways and relations once,
  initializes the connections, and returns relation handles:
  ```zig
  const App = zom.Container(.{
      .gateways = .{ .default = zom.memory.Gateway, .files = zom_csv.Gateway },
      .relations = .{ .users = .{ UserSchema, .default }, .imports = .{ ImportSchema, .files } },
  });
  var app = try App.init(allocator, .{ .files = .{ .path = "data/" } });
  defer app.deinit();
  const users = app.relations.users;
  ```
- Extract the memory adapter's engine as `zom.memory.Store(S)`.
- **Done when** memory passes the lint suite, and a fake read-only adapter in
  tests compiles for reads and fails to compile on `create` with the
  intended message.

### Phase 2: file adapters (`zom-csv`, `zom-yaml`)
These test the contract with the least effort, as rom-csv and rom-yaml did
for rom.
- `codec`: decode text cells into a tuple's field types (ints, floats,
  bools, enums, optionals, strings), with errors that give row and column.
  Encoding goes the other way.
- `zom-csv`: the gateway is a file or a directory (one dataset per `*.csv`,
  named after the file, as in rom-csv). Each dataset wraps `memory.Store(S)`.
  It's read-only by default, and `Config.writable = true` turns on writes
  plus `sync()`, which writes back atomically (temp file, then rename).
  The header row is checked against the schema's fields when the file loads.
- `zom-yaml`: the same structure, a top-level list of mappings per dataset.
  Nested values wait for Phase 4 (associations) or use flat schemas.
- **Done when** both pass the lint suite (write tests are skipped when
  read-only), and an example joins CSV users with in-memory posts through
  the container.

### Phase 3: SQL (`zom-sql`, then `zom-pg`)
- Grow the core query AST, still with fixed capacity:
  - `or`/`not` groups, `in` (with a bounded list or a sub-relation), `like`,
    `between`, `is null`
  - order by several fields
  - **projections**: `select(.{ .id, .name })` returns a relation over a
    narrower tuple type, built with `@Struct`
- `zom-sql`: a compiler with a `Dialect` (placeholder style, quoting,
  `RETURNING` support) for SELECT, INSERT (single and multi-row), UPDATE and
  DELETE. It owns identifier quoting.
- `zom-pg`: a gateway on `pg.zig` with a connection pool, parameters bound
  from `Value`, rows decoded into `S.Tuple` through `codec`, and
  `transaction` implemented. Postgres errors map to the shared error names
  (unique violation becomes `error.DuplicatePrimaryKey`).
- **Schema check.** A Zig schema can't be inferred from the database at
  compile time, so rom-sql's inference becomes:
  - a startup check `Gateway.verify(S)`, which compares `information_schema`
    with the struct and fails fast on missing columns or wrong types
  - later, a `zom-sql infer` build step that generates Zig schema structs
    from a live database
- Migrations are out of scope for v1. Users can run any migration tool.
- **Done when** zom-pg passes the lint suite against a Postgres container in
  CI, and the same relation code runs unchanged on memory and Postgres.

### Phase 4: associations and combine
- Declare associations in the schema:
  `.associations = .{ .posts = zom.hasMany(PostSchema, .user_id), .author = zom.belongsTo(UserSchema, .user_id) }`.
- `users.combine(.posts)` returns a combined relation whose `mapTo(Author)`
  fills `Author.posts`. It loads children with one dataset query,
  `where(.user_id, .in, parent_keys)`, and groups them with a hash map,
  replacing today's O(n·m) `combineMany`.
- Adapters that support `join` (SQL) can also offer `users.join(.posts)`.
- Associated changesets (rom-changeset's `associate`) set foreign keys on
  create.
- **Done when** combine works the same on memory, csv and pg, and
  `combineMany` is deprecated.

### Phase 5: repositories, transactions, plugins
- `zom.Repository(.{ .root = .users, .relations = .{ .users, .posts } })`
  holds view methods and command shortcuts. Custom relation views (rom's
  `def active = where(...)`) live on a wrapper struct around the generated
  relation.
- `container.transaction(.default, f)` delegates to the gateway's
  `transaction` capability, and gives a compile error when a gateway lacks
  it.
- Plugins as comptime mixins configured on the schema:
  - `timestamps` (sets `created_at`/`updated_at` in changesets)
  - `pagination` (`page(n).perPage(k)` with a total count)
  - `instrumentation` (a hook called around each dataset call, for logging
    and metrics)
- **Done when** the README example uses a repository and a transaction
  against pg.

### Phase 6: `zom-tigerbeetle`
TigerBeetle tests the contract hardest: fixed schemas, 128-bit ids,
immutable records, batched writes, and limited queries.
- Core work needed first: a `u128` `Value` variant (ids, `user_data_128`,
  amounts) and the `insertMany` capability (from Phase 1).
- Fixed schemas `zom_tigerbeetle.Account` and `zom_tigerbeetle.Transfer`
  that mirror the client's structs (or are those structs directly), with
  `id` as the primary key.
- Datasets:
  - `insert`/`insertMany` map to `create_accounts` and `create_transfers`,
    in batches of up to the client's limit (8189 events). Per-event result
    codes map to errors: `exists` becomes `error.DuplicatePrimaryKey`, and
    the others become typed errors returned in a result slice for batches.
  - No `update` or `delete` (records are immutable), so they're left out
    and `relation.update()` doesn't compile.
  - `read`: `byPk`/`where(.id, .in, ids)` becomes `lookup_accounts` or
    `lookup_transfers`. Filters on `user_data_*`, `ledger`, `code` and
    timestamp ranges become `query_accounts`/`query_transfers`. `.order(.timestamp, ...)`
    maps to the `reversed` flag, and `limit` maps to the filter limit. Any
    other filter is a compile error in `.strict` mode, or filtered in memory
    in `.fallback` mode.
  - Account history (`get_account_transfers`, `get_account_balances`) is
    exposed as an association or view: `accounts.byPk(id).combine(.transfers)`.
- Linked event chains (`flags.linked`) are exposed as a changeset that
  commits as one linked batch, which is TigerBeetle's form of atomicity,
  in place of `transaction`.
- The lint suite runs against a TigerBeetle dev cluster in CI, skipping the
  update/delete checks because those capabilities are absent.
- **Done when** a double-entry example (create accounts, post transfers,
  read balances) runs only through zom relations and changesets.

## 5. Order and dependencies

```
Phase 0 ─► Phase 1 ─┬─► Phase 2 (csv, yaml)
                    ├─► Phase 3 (sql, pg) ─► Phase 4 (associations) ─► Phase 5
                    └─► Phase 6 (tigerbeetle; needs u128 + insertMany from 0/1)
```

Phases 2, 3 and 6 can run in parallel once Phase 1's contract is frozen.
Phase 2 should land first, because it's the cheapest check that the
contract and `memory.Store` are right before the bigger adapters depend on
them.

## 6. Principles to keep

- **Compile-time checks first.** Mistakes in field names, value types,
  missing capabilities or unsupported query features should not compile.
- **Explicit limits, as in Tiger Style.** Filters, changes, `IN` lists and
  batch sizes have fixed capacities with asserts. Building a query never
  allocates.
- **Relations stay plain values.** No hidden I/O until a materializer or
  `commit` runs.
- **Callers own allocations.** Every function that returns a slice states
  who frees it, and adapters document how long the strings they return
  stay valid.
- **One rulebook for adapters.** Every adapter must pass `zom.lint` before
  release. That suite is what defines the contract, more than any prose.

## 7. Open questions

1. Should the adapter packages live in this repo under `adapters/`, or in
   separate repos from the start? This plan assumes they start in this repo.
2. Should `.fallback` (in-memory filtering of unsupported features) exist at
   all, or should zom be strict only? It's convenient, but it can hide full
   scans.
3. Should `Value` grow (`u128`, timestamps, bytes), or should each adapter
   bring its own value type? This plan grows the core `Value`.
4. Which SQLite wrapper should `zom-sqlite` use, and is it needed for v1?
