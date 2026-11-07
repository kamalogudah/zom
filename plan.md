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
| Schema | `Schema(Tuple, name, pk, options)`: a struct, a dataset name, a primary key, and associations (`hasMany`, `belongsTo`) checked at compile time. No attribute metadata. |
| Query | `Query(T)`: AND-only filters (`eq neq lt lte gt gte`), one `order`, `limit`, `offset`. Fixed capacity of 16 filters. |
| Value | `null`, `boolean`, `int` (i64), `uint` (u64), `float`, `string`. No `u128`, no timestamps, no bytes. |
| Relation | Immutable and lazy. `where/order/limit/offset/byPk`, `toSlice/one/first/count`, `mapTo/mapWith`, `create/update/delete`. |
| Changeset | `Create` (with `map` steps) and `Update` (`set`), committed explicitly. |
| Mapper | Copies fields by name, with renames. `combineMany` joins loaded slices in memory (O(n·m)). |
| Adapter seam | The contract is checked at compile time: `Gateway.Dataset(S)` and `dataset(S)`, plus `read count insert update delete` on the dataset. Every dataset call is fallible. |
| Adapters | `memory` (full), with primary keys enforced. `sql.compileSelect` (SELECT only, Postgres placeholders, no driver). |
| Packaging | One package, `zom`, with all adapters inside it. |

Every issue from the last review is fixed in 0.2.0, and the public API is
frozen there (see [CHANGELOG.md](CHANGELOG.md) and [docs/api.md](docs/api.md)).

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
├── value       Value union (adds uint64, uint128, timestamp, bytes; see 3.3)
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
└── zom-sqlite   translate-c binding over the SQLite amalgamation (post-v1)
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
| `count(query) !usize` | yes | Fallible since 0.2 (I/O). |
| `insert(T) !T` | no, `writable` | A read-only adapter leaves it out, and `relation.create` gives a compile error naming the adapter. |
| `insertMany([]const T) !usize` | no, `batch_insert` | Falls back to a loop over `insert`. TigerBeetle wants this. |
| `update(query, changes) !usize` | no, `updatable` | TigerBeetle leaves it out (its records are immutable). |
| `delete(query) !usize` | no, `deletable` | |
| `pub const supports: zom.Supports` | no | Which query features the adapter can handle (`or`, `in`, `like`, `order_on`, `offset`, `projection`, `join`). |

**Query support.** When a relation uses a feature the adapter's `supports`
leaves out, zom does one of two things, chosen per relation:
- `.strict` (the default): compile error, e.g. `zom-tigerbeetle cannot filter transfers on 'amount'`.
- `.fallback` (opt-in, per relation): the adapter evaluates the parts it supports, and zom filters the rest in memory with the existing `Query.matches`.

Fallback rules:
- A relation must turn on `.fallback` explicitly, so every place a scan can
  happen is visible in the code.
- Every fallback read reports itself through a scan hook set once on the
  `Container`, e.g. `on_scan(adapter_name, relation_name, rows_fetched,
  rows_returned)`. Tests assert on it, and apps log it.
- Once any filter runs in memory, `limit`, `offset` and (if it isn't pushed
  down) `order` run in memory too, after the filter. Otherwise pages come
  back short. `count` follows the same rule. The lint suite checks this.
- Fallback is a relation-level feature, so it doesn't change the adapter
  contract. It ships in Phase 3 as its own ticket, after strict mode.
- Writes never fall back: `update` and `delete` on a fallback relation
  return `error.UnsupportedFilter` when the dataset can't evaluate every
  filter. (Built in #34, with the optional `filterable(field, op)` hook on
  datasets for per-attribute support.)

**Errors.** The contract uses inferred error sets (`!T`), so each adapter's
errors flow through. The core defines the shared names every adapter must use
for the same condition: `error.DuplicatePrimaryKey`, `error.ValueOutOfRange`,
`error.NotFound`, `error.ReadOnly`, `error.ConnectionFailed`. The lint suite
checks these.

### 3.2 Packaging

- One package, several modules. The core is the `zom` module, and each
  adapter in `adapters/<name>/src` is exported by the root `build.zig` as
  `zom_<name>`. An application writes `b.dependency("zom", ...)` once and
  takes `.module("zom")`, `.module("zom_csv")` and so on. Separate packages
  per adapter (rom's gem-per-adapter layout) don't work inside one repo in
  Zig: a fetched package is the repo or tarball root, so an adapter in a
  subdirectory can't be fetched on its own, and a `.path = "../.."`
  dependency can't point outside the fetched package.
- Adapters with third-party dependencies take them as **lazy** dependencies
  behind a build option (`-Dpg`, `.pg = true` from a dependent), so an
  application only fetches what it uses.
- Adapters import zom only through its public module, so one can still move
  to its own repo without code changes.
- An adapter moves to its own repo only when it needs CI services the core
  doesn't (a Postgres container, a TigerBeetle cluster) and those jobs slow
  down or break core PRs, or when it needs its own release schedule. Until
  then zom-pg and zom-tigerbeetle live here too, with their service-backed
  CI jobs in separate workflows so they don't block core PRs. (zom-pg's is
  `.github/workflows/pg.yml`; `ci.yml` builds with `-Dpg=false`.)
- An application depends on `zom` plus the adapters it needs. `@import("zom")`
  and `@import("zom_csv")` are the only imports it needs, from one
  `b.dependency("zom", ...)`.
- `zom.memory` stays in core, like `ROM::Memory`, because tests, the lint
  suite and the file adapters all build on it.
- `zom.sql.compileSelect` moves out to `zom-sql`, so core has no SQL in it.
- `zom-sqlite` (post-v1) uses no third-party Zig wrapper. It fetches the
  SQLite amalgamation as a `build.zig.zon` URL dependency, compiles it with
  `addCSourceFile`, and binds `sqlite3.h` with `b.addTranslateC`. zom only
  needs about 15 functions (`open_v2`, `prepare_v3`, `bind_*`, `step`,
  `column_*`, `finalize`, `extended_errcode`, `close_v2`), since binding goes
  through `Value` and decoding through `zom.codec`. zig-sqlite's typed
  statement API would go unused, and on 2026-10-31 its Zig 0.16 support was
  incomplete (Windows CI failing, compatibility PRs unmerged). SQLite needs
  no CI container, so if Postgres in CI proves painful, zom-sqlite can become
  the first SQL driver instead.

### 3.3 Values

The core `Value` grows, instead of each adapter bringing its own value type:
filters and changes stay adapter-agnostic, which is what lets the same
relation code run on memory and Postgres.

| Tag | Payload | Schema field type | Notes |
|---|---|---|---|
| `uint` | `u64` | `u64` (and `usize` on 64-bit) | Added in 0.2 (#2). |
| `uint128` | `u128` | unsigned ints of 65 to 128 bits | `order` compares across int kinds by widening to `i129`. |
| `timestamp` | `i64` nanoseconds since the Unix epoch, UTC | marker type `zom.Timestamp{ .ns: i64 }` | Covers 1677 to 2262. Not `std.time.Instant`, which is a monotonic, platform-specific clock reading with no fixed epoch. A bare `i64` field still maps to `.int`. |
| `bytes` | `[]const u8` | marker type `zom.Bytes` | A separate tag from `string`, because `[]const u8` means string. Orders against `bytes` only. Text adapters encode it as base64 (details in the codec ticket). |

Done in #53: the `uint128` payload is declared `u128 align(8)`, so
`Value` keeps the 8-byte alignment of its string slice and stays 24 bytes
(a plain `u128` would raise it to 16-byte alignment and 32 bytes, and grow
the fixed-capacity filter and change arrays by the same ratio). zom-pg
binds it as bigint after a range check, like `uint`.

## 4. Phases

Each phase ends with `zig build test` green, the README updated, and the
lint suite covering the new contract surface.

### Phase 0: tidy the core (done in 0.2.0)
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
  var app: App = undefined; // init fills it in place: relations point into it
  try app.init(allocator, .{ .files = .{ .io = io, .path = "data/" } });
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
  `zom_csv.Gateway` is read-only; `zom_csv.WritableGateway` adds writes
  plus `sync()`, which writes back atomically (temp file, then rename).
  Writability is a second type rather than a `Config.writable` flag, because
  capabilities are the declarations a dataset type has, fixed at compile
  time. `Config` is `{ io, path, dir = .cwd(), separator = ',',
  null_text = "", unknown_columns = .reject, max_file_bytes = 64 MiB }`:
  the caller passes its `std.Io`, as with an allocator.
  The header row is checked against the schema's fields when the file loads
  (any column order; missing required, unknown or repeated columns are
  `error.SchemaMismatch`), and load errors leave a `file:row:col` message
  in `gateway.diagnostic`.
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
    from a live database. (Built in #41: the generator is
    `zom_sql.infer`, which needs no driver; the database side is zom-pg's
    `Gateway.introspect`, the `zom-pg-infer` executable and
    `addInferStep` in zom-pg's build.zig, since zom-sql can't depend on a
    driver.)
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
  Done: `join` / `whereJoined` on the relation (compile error without
  `supports.join`), a correlated `WHERE EXISTS` in zom-sql (decision 6;
  first rendered as `SELECT DISTINCT ... INNER JOIN`), and a hash semi-join
  in the memory gateway, checked by `zom.lint`.
- Associated changesets (rom-changeset's `associate`) set foreign keys on
  create.
- **Done when** combine works the same on memory, csv and pg, and
  `combineMany` is deprecated. Done: it carries a `/// Deprecated:` doc
  comment, and `-Dno-deprecated` turns each call into a compile error.

### Phase 5: repositories, transactions, plugins
- `zom.Repository(.{ .root = .users, .relations = .{ .users, .posts } })`
  holds view methods and command shortcuts. Custom relation views (rom's
  `def active = where(...)`) live on a wrapper struct around the generated
  relation.
- `container.transaction(.default, f)` delegates to the gateway's
  `transaction` capability, and gives a compile error when a gateway lacks
  it.
- Plugins as comptime mixins configured on the schema:
  - `timestamps` (sets `created_at`/`updated_at` in changesets). Done:
    hooks are found with `@hasDecl` and read a relation-held context with
    an injectable clock (`src/plugins.zig`).
  - `pagination` (`page(n).perPage(k)` with a total count). Done, as a
    method on every relation rather than a plugin: it adds no changeset
    hook, and a plugin cannot add methods to the relation type
    (`src/pagination.zig`).
  - `instrumentation` (a hook called around each dataset call, for logging
    and metrics). Done: `before` / `after` plugin hooks around every
    dataset call, a ready-made `instrumentation.log`, and zero-size spans
    without them (`src/plugins.zig`). Setting the hooks from a container,
    for schemas that don't declare them, is left out (see #51).
- **Done when** the README example uses a repository and a transaction
  against pg. Done: `examples/pg_repo` signs users up through a
  repository in `app.transaction(.db, ...)` (`Repository.fromRelations(tx)`
  builds one over the transaction's relations), and zom-pg's CI workflow
  runs it against Postgres.

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

## 7. Decisions

The four open questions were decided in #29:

1. Adapters live in this repo under `adapters/` (split criteria in 3.2).
   Revised on 2026-11-05: they ship as modules of the one zom package, not
   as separate packages, because separate packages in one repo couldn't be
   fetched (3.2).
2. `.fallback` exists, opt-in per relation, with a scan hook (3.1).
3. The core `Value` grows: `uint128`, `timestamp`, `bytes` (3.3).
4. `zom-sqlite` is post-v1 and uses a translate-c binding (3.2).

Later decisions:

5. **A combine target's `limit` / `offset` page each parent** (#77,
   2026-11-07). `users.combine(.posts, posts.order(.id, .desc).limit(3))` is
   each user's latest three posts. `error.PagedCombineTarget` is gone.
   - *Why this meaning:* children are read in ⌈keys / `max_in`⌉ batches,
     so a limit on the query would page each batch, which depends on
     `max_in` and means nothing. Per parent is the only useful meaning, so
     `limit` gets it, with no separate `perParent(n)` API.
   - *How:* in `combine.zig`, on every adapter. The limit and offset are
     taken off the target query, every matching row is read, and each group
     keeps its window in the relation's order. A nested level fills only
     the kept rows. A `loadAssociation` gets the query without them and its
     groups are windowed the same way, so its contract doesn't change.
   - *Cost:* on a dataset without the capability below, the whole
     association is read.
   - *Pushed down* (#87, 2026-11-07): a dataset with
     `supports.per_group_limit` pages each group itself. Through
     `whereIn`, combine keeps the limit and offset on each batch's query
     and sets `Query.per_group` to the target's key, and zom-sql renders
     `SELECT ... FROM (SELECT ..., ROW_NUMBER() OVER (PARTITION BY fk
     ORDER BY <order>) AS zom_rn FROM t WHERE ...) AS zom_paged WHERE
     zom_rn > offset AND zom_rn <= offset + limit ORDER BY <order>`. Each
     key is in exactly one batch, so a parent's page doesn't depend on
     `max_in`. Through `loadAssociation`, the dataset gets the limit and
     offset and pages each key's slice: zom-tigerbeetle asks
     `get_account_transfers` for `offset + limit` matches per account when
     it can (an order by `timestamp`, no row dropped by a filter checked in
     memory), and reads them all otherwise.
     - *A capability, not a new hook:* the batched read is still `read` /
       `readProjected`, with one more query field, so a dataset that pages
       in memory (memory, CSV, YAML) gets it for free through
       `Query.pageGroups`, and `.all` includes it. `count` never gets
       `per_group`.
     - *Only when the dataset runs the whole query:* rows a `.fallback`
       relation's in-memory filter drops must not count toward the page,
       and an offset the dataset can't skip would be applied to the whole
       result. Combine asks `runsInMemory()` of the batch query, page
       included, and pages in memory when it is true.
     - *Checked by `zom.lint`:* a dataset that declares it must read the
       same rows, in the same order, as `Query.pageGroups` over its full
       read, for groups with nulls, every row alone, past-the-end offsets,
       `limit(0)`, a filter, an `in` and a projection.
   - *Not a compile error:* `limit` is a runtime value, and with this
     meaning nothing needs refusing.

6. **A join renders as a correlated `WHERE EXISTS`, not `SELECT DISTINCT`
   over an `INNER JOIN`** (#82, 2026-11-07). `users.join(.posts)
   .whereJoined(.posts, .published, .eq, true)` is
   `SELECT "users"."id", ... FROM "users" WHERE EXISTS (SELECT 1 FROM
   "posts" WHERE "posts"."user_id" = "users"."id" AND "posts"."published" = $1)`,
   the same predicate joined `update` / `delete` already used (#81).
   - *Why:* it is the semi-join the memory gateway computes, so it needs no
     deduplication. `DISTINCT` compares whole rows, so it fails outright
     on a column with no equality (`json`: "could not identify an equality
     operator"), and it needed a derived table for a projection and for a
     dialect without `NULLS LAST` ordering by a nullable column. Both are
     gone. Select, update and delete now share one `WHERE` writer.
   - *Evidence:* `EXPLAIN ANALYZE` on Postgres 17, 100k users and 1M posts
     (about 10 per user, index on `posts.user_id`), times after a warm run:

     | query | DISTINCT + JOIN | EXISTS | EXISTS plan |
     |---|---|---|---|
     | published posts, `ORDER BY id LIMIT 20` | 4.0 ms | 3.9 ms | Merge Semi Join |
     | selective parent filter (`id < 100`) | 10.1 ms | 2.5 ms | Nested Loop Semi Join |
     | every user with a published post (100k rows) | 1244 ms | 756 ms | Hash Join over the aggregated keys |
     | the same, projected to `name`, `ORDER BY name LIMIT 20` | 1287 ms | 704 ms | the same, no Subquery Scan |
     | very selective joined filter (`likes >= 499`, 200 rows) | 143 ms | 160 ms | Hash Semi Join |

     `DISTINCT` sorts or hashes every joined copy of a parent row, which
     is what costs it. `EXISTS` stops at the first match per parent. The one
     case where it was slower, by 10 to 20% over two runs, is a tiny joined
     set: the planner hashes the 2,000 matching posts and then scans every
     user, where `DISTINCT` probes the users index per post. Both are
     dominated by the scan of `posts`, and it doesn't outweigh the rest.
   - *More than one join per query* (#88, 2026-11-07): one more
     `AND EXISTS (...)` per join, in the order joined, and one more key set
     in memory, each for its own joined row. `users.join(.posts).join(.comments)`
     means users with a post and with a comment, not with a post that has
     a comment (that is a nested join through `posts`, a separate
     question). `Query.joins` is a fixed array of `Query.max_joins` = 3
     `Join`s with a count, so queries stay copyable and allocation-free;
     each `Join` is about 760 bytes, which takes a query from about 1.9 KiB
     to 3.4 KiB. `whereJoined*` finds its join by association. The same
     association joined twice is a no-op, filters kept: a join is named by
     its association, so "a published post and an unpublished one" would
     need an explicit alias, not taken up until something asks for it.
     Aliases stay unique across the statement: a joined table goes by its
     own name, else its association's (a self-join, or a second join onto
     the same table), else `zom_joined_<n>`. Sibling `EXISTS` scopes would
     allow repeats, but unique aliases read better and survive nesting.
