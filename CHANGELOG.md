# Changelog

All notable changes to zom are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). While zom is on `0.x`, a minor
bump (`0.2` to `0.3`) may break the public API; a patch bump never does.

## [Unreleased]

## [0.17.1] - 2026-11-07

zom now builds with **Zig 0.17.1** (`minimum_zig_version = "0.17.1"`), and
its version moves to 0.17.1 to follow it. Zig 0.16 is no longer supported:
stay on the `v0.16.x` tags for it. Nothing changes in how zom behaves; the
test suite is the same as on 0.16.

### Changed

- **Breaking:** `zom.file.isRequired` takes a field's type and attributes,
  `isRequired(F, attrs)`, instead of a `std.builtin.Type.StructField`,
  which Zig 0.17 removed (`@typeInfo` gives a struct's fields as the
  parallel arrays `field_names`, `field_types` and `field_attrs`). A file
  format of your own calls it as
  `inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| ... zom.file.isRequired(F, attrs)`.
- zom-sqlite and zom-tigerbeetle translate their C headers with the
  [translate-c](https://codeberg.org/ziglang/translate-c) package (2.0.1)
  instead of the deprecated `b.addTranslateC`. It is a lazy dependency,
  fetched only with `.sqlite = true` or `.tigerbeetle = true`, and the same
  commit pg.zig uses, so the three share one copy.
- zom-pg pins pg.zig's `master` (`a9fb170`), which supports Zig 0.17, in
  place of its `zig-0.16.0` branch.
- `build.zig`: `zig build infer -- <args>` passes the arguments through
  `addPassthruArgs` (Zig 0.17 no longer shows them to `build.zig`), and the
  compile-error cases are registered as configure-time inputs, so adding or
  editing a case under `tests/compile_errors/` reconfigures the build.
- `-Doptimize` takes Zig 0.17's names: `debug`, `safe`, `fast`, `small`.

## [0.16.1] - 2026-11-07

### Added

- **zom-sqlite** (`adapters/sqlite`, module `zom_sqlite`, `.sqlite = true`):
  a gateway for SQLite on the SQLite 3.54.1 amalgamation, compiled into the
  module and bound with `translate-c` (no system library, no wrapper).
  Statements come from zom-sql's `.sqlite` dialect. It passes `zom.lint`
  and has every capability and query feature, joins and `combine`'s
  per-parent paging included. `transaction` nests as savepoints, and a
  failed statement doesn't abort the transaction around it. Errors map to
  zom's shared names plus `error.Busy`, with `Gateway.lastError()` for
  SQLite's code and message. Statements are kept per connection by their
  SQL text (`statement_cache_size`). Its tests run on in-memory databases,
  so `zig build test` covers it with nothing to set up.

## [0.16.0] - 2026-11-07

zom's version now follows the Zig release it builds with: 0.16.x builds
with Zig 0.16.0 (`minimum_zig_version = "0.16.0"`). Everything below was
added since 0.2.0.

### Changed

- **Breaking (zom-tigerbeetle):** `zom_tigerbeetle.AccountBalance` has no
  primary key (it was keyed by `timestamp`, which is unique per account,
  not overall: a transfer moves both its accounts' balances).
  `balances.byPk(ts)` is now a compile error instead of
  `error.AccountIdRequired`; use
  `where(.account_id, .eq, a).where(.timestamp, .eq, ts)`. A schema of your
  own over `tb.AccountBalance` must be declared with `null` too. (#84)

- zom-sql renders a joined select (`users.join(.posts)`) as a correlated
  `WHERE EXISTS (SELECT 1 FROM "posts" WHERE "posts"."user_id" = "users"."id" AND ...)`
  instead of `SELECT DISTINCT ... INNER JOIN ... ON ...`. The rows are the
  same. Joined tables can now have `json` columns, a projection or a
  `NULLS LAST`-less sort no longer needs a derived table, and Postgres plans
  it as a semi-join (as fast or faster in the `EXPLAIN ANALYZE` comparison
  recorded in plan.md §7, item 6). Select, update and delete share one
  `WHERE` writer. (#82)

### Added

- zom-pg prepares statements by name and keeps them per connection: a
  statement whose SQL text repeats (a `byPk` get, every `combine` level,
  `insertMany` batches) is parsed once per connection, then only bound and
  executed. At most `Config.statement_cache_size` (default 256, `0` turns it
  off) per connection, closing one to make room. A statement that DDL has
  invalidated (`0A000`) or that was dropped (`26000`) is prepared again and
  the call retried, outside a transaction. (#89)

- More than one join per query: `users.join(.posts).join(.comments)` keeps
  the users with a post and with a comment, each join matched (and
  narrowed by its own `whereJoined*`) on its own rows. Up to
  `Query.max_joins` (3) joins; a fourth panics, and joining an association
  already joined is still a no-op. zom-sql renders one `AND EXISTS (...)`
  per join, in the order joined, for select, update and delete, aliasing a
  joined table by its association (or `zom_joined_<n>`) when the parent or
  an earlier join already uses its name. The memory gateway builds one
  semi-join key set per join. **Breaking (adapters):** `Query.join: ?Join`
  is now `Query.joins` / `join_count`, read through `joinSlice()`, and
  `zom.lint`'s join check also seeds and joins `lint_comments`
  (`zom.lint.Comments`), which a factory for a dataset with `supports.join`
  must provide. (#88)

- Per-parent paging pushed down to the dataset: a combine target's
  `limit` / `offset` now go to a dataset with the new
  `supports.per_group_limit` capability instead of being applied after
  reading every matching row. `Query.per_group` names the attribute whose
  groups they page (nulls as one group), and `Query.pageGroups` applies it
  in memory. zom-sql renders it as `ROW_NUMBER() OVER (PARTITION BY ...)`
  in a derived table filtered on the row number, so zom-pg sends back only
  the rows kept, across every ⌈keys / `max_in`⌉ batch. zom-tigerbeetle's
  datasets page each account's `get_account_transfers` /
  `get_account_balances` scan, and its `loadAssociation` each key's slice.
  The memory and file adapters (`Supports.all`) honour it too. A
  `.fallback` target that filters, sorts or skips in memory is still paged
  by combine, since the rows it drops must not count. `zom.lint` checks a
  dataset that declares it against `Query.pageGroups`, and
  `relation.runsInMemory()` says whether a read would evaluate part of its
  query in memory. A hand-written dataset that copies `Supports.all` must
  now honour `query.per_group`, or turn `per_group_limit` off. (#87)

- Views: `zom.Schema(T, name, null, options)` declares a schema without a
  primary key, with `has_primary_key == false`. `byPk`, `S.primary_key`,
  a `belongsTo` pointing at it and a `hasMany` / custom association on it
  are compile errors. A `belongsTo` from it and a `hasMany` into it work.
  The memory store skips its duplicate-key checks, and zom-pg's `verify`
  its primary-key check. (#84)

- Joined `update` and `delete` use the same semi-join selection as reads.
  zom-sql renders a correlated `EXISTS` predicate, and memory selects
  matching rows before mutation. A join alone bounds a SQL write. (#81)
- Boolean groups and runtime lists on joined rows:
  `whereJoinedAny(.assoc, conds)` and `whereJoinedNot(.assoc, cond)` take
  the conditions `whereAny` / `whereNot` take, over the joined tuple (so
  "users with a post that is published or has 10+ likes" can be written),
  and need `supports.or` on the joined dataset (a compile error
  otherwise). `whereJoinedIn` / `whereJoinedNotIn` take a runtime slice,
  borrowed like `whereIn`. `zom.Join` now stores its filters as the same
  flat node tree as `Query` (`zom.query.FilterNode`, up to
  `Join.max_nodes = 16`), zom-sql renders it, and `Join.targetQuery`
  rebuilds the groups for the memory semi-join. `Join.filterSlice()` now
  asserts `isConjunction()`; walk `topNodes()` for a join with groups. (#80)
- `combine` checks its key type: a key it can't hash (a float, a struct, an
  array or a slice other than a string) is a `zom.combine` compile error
  naming the type, not an error from inside `std.hash`. `u128` keys
  (TigerBeetle ids) are tested in both directions. The supported key types are listed in
  the README's "Combine" section. (#79)
- `combine` into a relation that already has `Query.max_filters` filters
  (or `max_nodes` nodes) returns `error.CombineTargetFull`, at every level
  of a nested combine, instead of panicking in `Query.reserve` over the
  `whereIn` it adds. A target dataset with `loadAssociation` adds no
  filter and is not limited. (#85)
- Per-parent paging in `combine`: a `limit` or `offset` on the target
  relation now pages each parent's rows, so
  `users.combine(.posts, posts.order(.id, .desc).limit(3))` gives every
  user their latest three posts. It used to be `error.PagedCombineTarget`,
  which is gone. Every matching row is still read (the page is applied in
  memory, on every adapter), a nested level fills only the rows kept, and
  a `loadAssociation` gets the query without them. (#77)
- Nested combines: the relation passed to `combine` can be a combine,
  `users.combine(.posts, posts.combine(.comments, comments))`, to any
  depth. The element type of the association field (e.g.
  `PostWithComments`) is mapped by attribute name and gets its own
  association filled; the field-shape checks and paging apply at every
  level. Each level runs once over all the rows of the level above, so a
  combine makes one source read plus Σ ⌈keys / `max_in`⌉ queries across
  its levels, and one `deinit()` frees the whole tree. Inner levels into a
  dataset with `loadAssociation` load through it (#75).
- `examples/double_entry`: two accounts on one ledger, a deposit, a linked
  chain that posts and one that is refused as a whole, then the balances
  and the customer's history, through zom relations and changesets only.
- CI for zom-tigerbeetle (`.github/workflows/tigerbeetle.yml`): the pinned
  `tigerbeetle` 0.17.9 binary, a `--development` cluster, the adapter's
  tests against it (failing on any skipped cluster test) and the
  double-entry example.
- `zom.lint.capabilitySkips(G, S)` and `zom.lint.printSkips(G, S)`: the
  checks a dataset lacks a capability for, with `run`'s reasons, for an
  adapter that can't run `run` itself. zom-tigerbeetle's lint read test
  reports lint's update and delete checks as skipped with them.
- zom-tigerbeetle README: what's supported, what isn't and why, and the
  strict / fallback behaviour.
- zom-tigerbeetle linked chains: `relation.linked().add(a).add(b).commit()`
  creates its events (transfers or accounts) all or nothing, in one
  request, with `flags.linked` set on a copy of every event but the last
  and the other flags kept. A chain holds up to 32 events, with no
  allocation. A failure is the causing event's own error, not
  `linked_event_failed`, and `reportTo(&failure)` gives its index and
  result code. A chain longer than one request holds is
  `error.LinkedChainTooLong`, unsent. ([#58])
- Adapter contract: a dataset may define `LinkedChangeset(Rel)`, which
  `relation.linked()` returns (a compile error naming the adapter
  otherwise), and a gateway without transactions may declare
  `transaction_hint`, which `container.transaction`'s compile error adds.
  ([#58])
- zom-tigerbeetle account history: `accounts.combine(.transfers, transfers)`
  loads each account's transfers through `get_account_transfers` (debit
  and credit side), and `.combine(.balances, balances)` its balance history
  through `get_account_balances`. `Account` declares `transfers` (a custom
  association) and `balances` (`hasMany` on `account_id`), and `Transfer`
  declares `debit_account` and `credit_account` (`belongsTo`, read through
  `lookup_accounts`). The new read-only `zom_tigerbeetle.AccountBalance`
  view (rows of `tb.AccountBalance`, keyed by `timestamp`) needs an
  `account_id` filter, else `error.AccountIdRequired`. The record datasets'
  `loadAssociation` picks the request per association at compile time: a
  `hasMany` on `debit_account_id` / `credit_account_id` reads one side, one
  on an indexed field is one `query_*` per key, and any other is a compile
  error. ([#57])
- Custom associations: `zom.customAssociation(Target, .tag, .many | .one)`
  declares an association with no foreign key zom can use
  (`AssociationKind.custom`). `Association` gains `cardinality`
  (`zom.Cardinality`), `tag` and `Key()`. A custom association can't be
  joined or associated (compile errors). ([#57])
- Adapter contract: an optional `loadAssociation(comptime a, keys, query,
  allocator)` on a dataset takes over every `combine` into it, in place of
  the `in` queries and hash-map grouping. It returns one slice of rows per
  key, allocated in the result's arena. Combining a custom association
  needs it. ([#57])

- zom-tigerbeetle reads: `byPk` and `where(.id, .in, ...)` are one
  `lookup_accounts` / `lookup_transfers`; `eq` on `user_data_128/64/32`,
  `ledger` and `code` and `timestamp` ranges (`eq`, `lt`, `lte`, `gt`,
  `gte`, `between`) are `query_accounts` / `query_transfers` with one
  `QueryFilter`; `order(.timestamp, .desc)` is its `reversed` flag, and
  `limit` its limit, paged with a timestamp cursor past 8189 rows. The
  datasets declare `supports` (`in`, no `offset`), `filterable` and
  `orderable`, so any other filter, order, or `offset` is a compile error
  on a strict relation (`its dataset's `filterable` rejects `.gt` on
  'amount'`) and runs in memory with `allowFallback()`. Every returned row
  is checked against the whole query, so values a `QueryFilter` can't hold
  (`user_data_64 = 0`, where 0 means no filter) are still right. TigerBeetle
  has no count, so `count` pages through the matches without keeping them.
  Reads and counts are bounded by `Config.scan_max` (2^20 rows,
  `error.ScanLimitExceeded`). `error.Unimplemented` is gone. zom.lint can't
  run on TigerBeetle's fixed schemas; a live test runs its read checks'
  queries on accounts against the same queries evaluated in memory. ([#56])
- Adapter contract: an optional `orderable(comptime field) bool` on a
  dataset narrows ordering per attribute, as `filterable` does filters.
  `Adapter.orderGap` consults it, so a strict relation ordering by a
  rejected field doesn't compile and a `.fallback` one sorts in memory.
  zom.lint skips a check that orders by an attribute the dataset can't.
  ([#56])
- zom-tigerbeetle inserts: `create` / `createMany` (the datasets' `insert`
  and `insertMany`) on `create_accounts` / `create_transfers`. `insert`
  returns the row with the `timestamp` the cluster gave it. `insertMany`
  splits rows into requests the cluster takes, never inside a linked chain
  (`error.LinkedChainTooLong` for a chain that can't fit). The limit isn't
  exposed by `tb_client.h`, and it is 253 on a `--development` cluster, not
  8189, so the gateway learns it from the client's refusals, which send
  nothing (`Config.batch_max` caps it; `batchLimit()` and `requestCount()`
  show it). Result codes are `results.CreateAccountResult` /
  `CreateTransferResult`, generated from the header; each becomes a typed
  error (`error.ExceedsCredits`, ...), and the `exists*` codes become
  `error.DuplicatePrimaryKey`. A code with no error is a compile error.
  `insertMany` fails with the first failing row's error, but sends every
  batch; `insertManyResults(rows, allocator)` lists each row not created
  with its code. `update` / `delete` are compile errors naming the adapter
  (`adapters/tigerbeetle/tests/compile_errors`, run by `test-tigerbeetle`).
  ([#55])
- zom-tigerbeetle (scaffold): the `zom_tigerbeetle` module, built with
  `-Dtigerbeetle` (`.tigerbeetle = true` from a dependent; on in a
  checkout). It links TigerBeetle's prebuilt C client from the
  tigerbeetle-go `v0.17.9` tarball, a lazy dependency, and translates
  `tb_client.h` with `b.addTranslateC`. TigerBeetle's releases pin Zig
  0.14.1, so building from its source was ruled out; the reasoning is in
  `adapters/tigerbeetle/README.md`. The fixed schemas `Account` and
  `Transfer` use the client's `tb_account_t` / `tb_transfer_t` directly,
  keyed by `id`. `tb.AccountFlags` / `tb.TransferFlags` are typed
  `packed struct(u16)` views of `flags`. `Gateway.init` starts the client
  from `cluster_id` and `addresses`. There is no `update`, `delete` or
  `transaction`, and `read` / `count` return `error.Unimplemented` until
  #56. `zig build test-tigerbeetle`; its cluster test needs
  `ZOM_TB_ADDRESSES`. ([#54])
- `zom.Value.uint128: u128` for unsigned integers of 65 to 128 bits
  (TigerBeetle ids, `user_data_128`, amounts). `toValue`, `fromValue`,
  `order` and `eql` handle it, comparing exactly against `int` and `uint`
  by widening to `i129`; integer literals above `maxInt(u64)` become
  `uint128`. The payload is stored at 8-byte alignment, so
  `@sizeOf(Value)` stays 24 on 64-bit targets. `zom.codec` parses and
  formats `u128` fields. zom-pg binds it as bigint after a range check and
  returns `error.ValueOutOfRange` past 2^63-1, as for `uint`. Signed
  integers wider than 64 bits are still a compile error. ([#53])
- `Repository.fromRelations(relations)`: a repository over a container's
  `Relations` value, such as the `tx` that `app.transaction(.gw, ctx, f)`
  passes to `f`, so a repository's relations can run in a transaction.
  `init(&app)` is `fromRelations(app.relations)`. ([#52])
- `examples/pg_repo`: a container on zom-pg, a repository with a custom
  view, and a sign-up in a transaction that rolls back on a deliberate
  error, with `schema.sql`. zom-pg's CI workflow runs it against Postgres
  and checks its output. The README's Usage section is built around it,
  with a section on reading error return traces. ([#52])
- `relation.page(n).perPage(k)`: page `n` (from 1) of `k` rows, read as
  `offset((n - 1) * k).limit(k)`. Its `paginate(allocator)` returns
  `zom.pagination.Result` with `rows`, `total` (the count without limit
  and offset), `page`, `per_page` and `pages`. A literal `page(0)` or
  `perPage(0)` is a compile error, a runtime one a panic, and an offset
  past `usize` is `error.ValueOutOfRange`. On every relation rather than
  a schema plugin, since it adds no changeset hook. ([#50])
- `relation.freeRows(allocator, rows)`: `free` without a relation value. ([#50])
- Instrumentation plugins: a plugin with `before(event)` and/or
  `after(event, outcome)` hooks is called around every dataset call that
  relations and changesets make (`read`, `count`, `insert`, `insert_many`,
  `update`, `delete`), with the adapter, dataset, op and query, then the
  row count, the `@errorName` of any error and the duration from the
  plugin context's clock (`Clock.ticks`, monotonic for an `.io` clock).
  `zom.plugins.instrumentation.log(std.log.scoped(.zom))` is a ready-made
  hook. A `.fallback` read reports every row the dataset returned. A
  schema without these hooks gets an empty span: no clock read, no call.
  ([#51])

### Fixed

- zom-tigerbeetle: a relation over a `zom.Schema` of your own over
  `tb.Account` or `tb.Transfer` compiles. `Gateway.Dataset(S)` is now the
  fixed schema's dataset type, which `gateway.dataset(S)` returns. ([#57])
- The memory adapter no longer overflows on `offset(n).limit(k)` when
  `n + k` is past `usize`, e.g. `limit(maxInt(usize))`. ([#50])

### Added

- Schema plugins: `zom.Schema(T, name, pk, .{ .plugins = .{ ... } })` takes
  comptime mixins with optional `validate`, `beforeCreate` and
  `beforeUpdate` hooks, which `Create.commit`, `CreateMany.commitAlloc` and
  `Update.commit` call in order. Hooks read a `zom.plugins.Context` set with
  `relation.withPluginContext(ctx)` or `app.setPluginContext(ctx)`. A schema
  without plugins compiles as before. ([#49])
- `zom.plugins.timestamps(.{ .created = .created_at, .updated = .updated_at })`:
  sets both `i64` fields on create and `updated_at` on update, from the
  context's injectable `zom.plugins.Clock` (`.io`, `.fixed` or `.func`).
  A missing or non-`i64` field is a compile error. ([#49])
- `createMany(...).commit()` on a schema with a `beforeCreate` plugin is a
  compile error: the hooks run on a copy, so use `commitAlloc`. ([#49])

- `app.transaction(.gateway, ctx, f)` on `zom.Container`: runs `f(ctx, tx)`
  in that gateway's `transaction`, where `tx` is an `App.Relations` whose
  relations on that gateway are rebound to the transaction and the rest
  are unchanged. A gateway without the `transaction` capability, or an
  unknown gateway name, is a compile error. ([#48])
- `zom.memory.Gateway.transaction(ctx, f)`: saves every store's rows and
  puts them back if `f` fails; calls nest. The memory gateway now has the
  `.transaction` capability. ([#48])

- `zom.Repository(App, .{ .root = .users, .relations = .{ .users, .posts } })`,
  rom-repository's root repository: `init(&app)` copies the listed relations
  out of a container into `repo.relations`, and `byPk`, `where`, `all`,
  `create`, `createMany`, `update` and `delete` forward to the root
  relation, keeping its capability compile errors. Custom views live on a
  wrapper struct with a `rel` field, named in `.relations` (`.{ .users =
  Users, .posts = .plain }`). An unknown relation, or a root that isn't
  listed, is a compile error.
- A `no-deprecated` build option. With `-Dno-deprecated`, using a
  deprecated declaration is a compile error that names its replacement.
  zom's source reads it as `@import("build_options").no_deprecated`.
- `relation.associate(.assoc, parent)`, ROM's `changeset.associate(user)`
  with the parent first: `posts.associate(.author, user).create(.{ ... })`
  takes the tuple without the foreign key (`Input`) and sets it from the
  parent's key; `.createMany(rows)` does the same for a batch and commits
  with `commitAlloc(allocator)`. Associations chain, for a row with several
  parents. ROM's order works on whole tuples too:
  `create(tuple).associate(...)` and `createMany(tuples).associate(...)`
  overwrite the key. The parent must be the target's tuple or a `select` of
  it that kept the key, and the association a `belongsTo`; anything else is
  a compile error. `create` keeps taking a whole tuple, because a partial
  struct would mean an `anytype` parameter, and Zig 0.16 literals would lose
  their result type; see `src/changeset.zig`.
- Associations on schemas: `zom.hasMany(Target, .fk)` and
  `zom.belongsTo(Target, .fk)` in `.associations`, read back with
  `S.association(.name)` or `S.associations.name` as a `zom.Association`.
  Foreign keys are checked at compile time (the field exists on the right
  tuple, and its type is the key's type or that type made optional), and so
  are association names. Schemas that refer to each other declare their
  associations as `struct { pub const posts = ...; }`, which Zig evaluates
  only after both schemas exist; see `src/schema.zig`.
- `relation.combine(.assoc, target)`, ROM's `users.combine(:posts)`: a lazy
  combined relation whose `mapTo(E, allocator)` / `mapWith(M, allocator)`
  read the source once, read the target with one `whereIn` query per
  `Query.max_in` keys, group the rows with a hash map (O(n + m)), and fill
  `E`'s association field: `[]const X` for `hasMany`, `?X` for
  `belongsTo`. The result is a `zom.CombineResult(E)` whose arena owns the
  whole tree; free it with `deinit()`. See `src/combine.zig`.
- `relation.join(.assoc)`, ROM's `users.join(:posts)`: the rows with at
  least one row of the association's target, each once, as a relation of
  the same type, so filters, order, paging, `select` and `combine` still
  apply. `whereJoined(.assoc, field, op, value)` filters the joined rows,
  typed like `where` on the target's tuple. Both are compile errors unless
  the dataset has `supports.join`, in `.fallback` mode too. The join lives
  in `query.join`, a `zom.Join` of static strings and a fixed array of up
  to 8 filters, so queries stay copyable and allocation-free. zom-sql
  renders `SELECT DISTINCT ... INNER JOIN ... ON ...` with every column
  qualified (a projection reads from a derived table, so `DISTINCT` still
  sees whole rows); zom-pg sets `supports.join`; the memory gateway runs a
  hash semi-join. `zom.lint` has a join check, run when `supports.join` is
  set, which also uses a second schema, `zom.lint.Posts` (`lint_posts`).
- A `zom.Mapper` exposes the `options` it was made with, and
  `zom.mapper.isMapper(M)` tells one from a hand-written mapper.
  `Combined.mapWith` uses both to rebuild a `zom.Mapper` so the association
  field needs no default. The field-skipping this needs is internal: a
  public mapper always sets every field (#78).
- `Combined.mapWith` takes a hand-written mapper (a struct with `Input`,
  `Output` and `call(Input) Output`), used as is: its `call` sets the
  association field and combine overwrites it. Anything else is a compile
  error naming what is missing (#78).

### Changed (breaking)

- `update` and `delete` on a joined relation return `error.JoinedWrite`,
  and `writeQuery` can now fail with it. zom-sql's `compileUpdate` and
  `compileDelete` return it for a joined query (`WriteError` grows).
- csv and yaml datasets no longer claim `supports.join`: their stores
  can't reach another dataset.
- `zom.lint.Users` declares a `posts` association. A factory for an
  adapter with `supports.join` must also provide an empty `lint_posts`
  dataset (zom-pg's creates the table).

- `zom.Schema` takes a fourth argument, its options: write
  `zom.Schema(T, name, pk, .{})` where you wrote `zom.Schema(T, name, pk)`.
  Zig has no default arguments or overloading, so the 3-argument form can't
  stay under the same name. zom-sql infer generates the new form.
- The adapters are modules of the zom package instead of separate packages.
  `adapters/<name>/build.zig` and `build.zig.zon` are gone; the root
  `build.zig` exports `zom_csv`, `zom_yaml`, `zom_sql` and, with
  `-Dpg=true` (`.pg = true` from a dependent), `zom_pg`. Depend on zom once
  and take `dep.module("zom_csv")` and so on. Before this, the adapters
  were outside zom's `.paths` and couldn't be fetched at all. pg.zig is now
  a lazy dependency of zom, fetched only when zom-pg is built.
  `addInferStep` moved to zom's build.zig: `@import("zom").addInferStep`.
  `zig build test-pg` runs zom-pg's tests from the root. Fetched packages
  (`zig-pkg/`) are no longer committed.
- CI is two workflows: `ci.yml` (core, csv, yaml, sql, examples, with
  `-Dpg=false`) and `pg.yml` (zom-pg against a Postgres container), so a
  Postgres failure no longer fails the core's run. The pg step now runs
  with `pipefail`, so a failing test can't pass behind `tee`.

### Deprecated

- `zom.combineMany`: use `relation.combine(.assoc, target)`, which reads the
  children with one `in` query and groups them in O(n + m) where
  `combineMany` matched loaded slices in O(n·m). Instead of

      const authors = try users.mapWith(AuthorMapper, arena);
      try zom.combineMany(.{ .into = "posts", .parent_key = "id", .child_key = "user_id" },
          arena, authors, try posts.toSlice(arena));

  declare `.posts = zom.hasMany(PostSchema, .user_id)` on the users schema
  and write

      var authors = try users.combine(.posts, posts).mapWith(AuthorMapper, allocator);
      defer authors.deinit(); // authors.items

  `combineMany` still works, and will be removed in a later 0.x release.
  Build with `-Dno-deprecated` (`.@"no-deprecated" = true` from a
  dependent) to make every call a compile error. ([#46])

### Removed (breaking)

- `zom.sql` is gone from the core, which now has no SQL in it. The compiler
  moved to the `zom-sql` package in `adapters/sql` (`@import("zom_sql")`):
  `zom.sql.compileSelect(T, allocator, table, query)` becomes
  `zom_sql.compileSelect(.postgres, T, allocator, table, query)`, or
  `zom_sql.compileRelation(.postgres, allocator, relation)`, and
  `zom.sql.writeIdent(list, allocator, name)` becomes
  `zom_sql.writeIdent(dialect, writer, name)`, writing to a
  `*std.Io.Writer`. `zom.Op.sql()` is removed too; SQL spellings live in
  zom-sql. ([#35])

### Added

- zom-pg, a PostgreSQL gateway in `adapters/pg` on pg.zig (pinned to the
  `zig-0.16.0` branch, commit `1f2bf9e`). A `pg.Pool` from a URL or
  separate fields, statements from zom-sql, `zom.Value` params bound
  through `pg.Stmt`, rows decoded by column name, `count` over the compiled
  `SELECT`, `insertMany` in one transaction, and Postgres errors mapped to
  the shared names (`23505` is `error.DuplicatePrimaryKey`). It passes the
  full lint suite, which runs when `ZOM_PG_URL` is set. ([#37])

- zom-pg transactions: `Gateway.transaction(ctx, f)` runs `f(ctx, tx)`
  between `BEGIN` and `COMMIT`, or `ROLLBACK` when it fails, and returns
  `f`'s error unchanged. `tx` is a `*Gateway` pinned to one pooled
  connection, so relations over it run in the transaction. Nested calls
  are SAVEPOINTs, and so is `insertMany` inside a transaction. ([#38])

- zom-pg schema check: `Gateway.verify(S, diagnostics)` compares the table
  `S.name` resolves to with `S.Tuple` at startup, through
  `information_schema`. Every field needs a column whose type holds it
  (`zom_pg.pgTypesFor`: a `u32` needs `bigint`, an enum `text` or a
  Postgres `ENUM`), optional fields need nullable columns and the others
  `NOT NULL`, and the primary key must be `S.primary_key` alone. It
  reports every mismatch at once (`users.age: Zig u8 vs pg text`) in a
  `zom_pg.Diagnostics`, or logs them when that is null, and returns
  `error.SchemaMismatch`. ([#39])

- Schema inference: `zom-pg-infer` writes a Zig struct and `zom.Schema`
  for every table of a Postgres schema, and `addInferStep(b, .{ .out =
  "src/schemas.zig" })` in zom-pg's build.zig wires it into an
  application's `zig build infer`. `Gateway.introspect(allocator, schema)`
  reads the tables through the same `information_schema` queries as
  `verify` (now shared in `catalog.zig`), and `zom_sql.infer.render` turns
  the catalog into source formatted by `std.zig.Ast`: names that aren't
  valid identifiers are quoted with `@"..."`, Postgres enums become Zig
  enums, nullable columns `?T = null`, and columns zom-pg can't decode
  (`uuid`, timestamps) are left out with a comment. `verify` accepts every
  struct it generates. ([#41])

- CI (`.github/workflows/ci.yml`): `zig fmt --check`, then `zig build test`
  for the core and every adapter and example, then zom-pg's tests against a
  Postgres 17 service container, failing if any of them is skipped. A
  shared scenario (`adapters/pg/src/scenario_test.zig`) runs the same
  relation code, written once as `scenario(comptime G: type, gw: *G)`, on
  the memory gateway and on zom-pg. ([#40])

- Caller-owned strings. A dataset can declare `pub const strings:
  zom.StringOwnership = .caller`: the strings it returns are allocated with
  the allocator passed to `read` / `readProjected` / `insert`, which then
  takes one (`insert(*Self, Tuple, Allocator)`). Relations gain
  `free(allocator, rows)` and `freeOne(allocator, tuple)`, and `Create`
  gains `commitAlloc(allocator)`; all three work on every adapter, so code
  that frees through them runs unchanged on memory and Postgres. zom frees
  the strings it drops itself: in `.fallback` reads, in `select` mapped down
  by zom, in `one`'s extra row, in `count` on a fallback relation, and the
  attributes a `mapWith` mapper leaves out. `zom.strings` has the helpers
  (`freeFields`, `freeAll`, `dupeFields`), and `Mapper.sources` lists the
  fields a mapper copies. ([#37])

- zom.lint frees what it reads with `free` / `freeOne` and creates with
  `commitAlloc`, so a caller-owned adapter is leak-checked too, and checks
  that strings from one read survive later reads (pg.zig reuses its row
  buffer). ([#37])

- zom-sql, a dialect-aware SQL compiler. `zom_sql.Dialect` (`placeholder`,
  `quote`, `returning`, `ilike`, `nulls_order`, `limit_all`) is a comptime
  argument with `Dialect.postgres` and `Dialect.sqlite` presets. It renders
  the whole query AST: `AND` / `OR` / `NOT` groups with parentheses, `IN`
  and `NOT IN` (empty lists become `1=0` / `1=1`, or a form that stays
  unknown for null on a nullable attribute, so results match the memory
  adapter), `LIKE` with `ESCAPE '\'`, `ILIKE` (`LOWER(x) LIKE LOWER(y)` on
  SQLite), `BETWEEN`, `IS [NOT] NULL`, several `ORDER BY` keys with `NULLS
  LAST` / `NULLS FIRST` on nullable keys to match memory's null ordering, and
  projections (`compileRelation` reads a `select`ed relation's columns;
  `compileProjected` takes the narrower struct). `writeSelect` renders into
  any `*std.Io.Writer`. SQLite gets `LIMIT -1` before a bare `OFFSET`.
  ([#35])

- zom-sql compiles writes. `compileInsert` renders `INSERT INTO "t" (...)
  VALUES (...)`, plus `RETURNING *` when the dialect has it.
  `compileInsertMany` renders multi-row `VALUES (...), (...)` and returns a
  `Batch` of statements, split so none carries more than the dialect's new
  `max_params` (Postgres 65535, SQLite 32766) bind parameters.
  `compileUpdate` renders `UPDATE "t" SET ... WHERE ...` with placeholders
  numbered on from `SET` into `WHERE`, and `compileDelete` renders `DELETE
  FROM "t" WHERE ...`. `writeInsert` / `writeUpdate` / `writeDelete` render
  into any writer. As a safety rule, an `UPDATE` or `DELETE` with no filters
  is `error.UnboundedWrite` unless the new `Query.all` is set; an update with
  no changes is `error.EmptyUpdate`. ([#36])

### Fixed

- `limit` and `offset` above the largest bigint are clamped to it in SQL;
  `LIMIT 18446744073709551615` was rejected by Postgres. ([#35])

- Query support is enforced. A relation is `.strict` by default: a filter,
  sort key or `offset` its dataset's `supports` leaves out is a compile error
  naming the adapter, the relation, the call and the missing feature (`in`
  for `in`/`not_in`/`whereIn`, `like` for `like`/`ilike`, `or` for
  `whereAny`/`whereNot` and every condition inside them, `order_on` for
  ordering by anything but the primary key, `offset`). Datasets may declare
  `pub fn filterable(comptime field: []const u8, comptime op: zom.Op) bool`
  to narrow support per attribute; `zom.Adapter` checks its signature, and
  `Adapter.filterGap` / `orderGap` say why something is unsupported.
  `users.allowFallback()` switches to `.fallback`: the dataset reads the
  supported top-level conditions, and zom filters the rest in memory with
  `Query.matches`, then sorts (when the dataset can't), offsets and limits,
  so pages are never short. That means reading every row the supported part
  matches, so each such read calls a scan hook with `zom.Scan{ adapter,
  relation, rows_fetched, rows_returned }`, set with `Container(.{ ...,
  .on_scan = hook })` or `relation.onScan(hook)`. A fallback relation's
  `count` takes an allocator, and its `update`/`delete` return
  `error.UnsupportedFilter` rather than writing through an in-memory filter.
  New exports: `RelationWith(S, G, Output, mode)` (`RelationOf` is its
  `.strict` form), `Mode`, `Scan` and `ScanHook`. `Query.addNodeFrom(src, index)` copies one
  top-level condition from another query, which is how a query is split
  without allocating. ([#34])

- Projections. `users.select(.{ .id, .name })` returns a relation whose
  reads (`toSlice`, `one`, `first`, `mapTo`) give `zom.Project(Tuple, .{ .id,
  .name })`, a struct built with `@Struct` that has only those fields, in that
  order, with their types and defaults. Reading a field that wasn't selected
  is a compile error, and so are an empty list, an unknown field and a field
  listed twice. The query stays typed on the full tuple, so filters and
  orders may use attributes that weren't selected. The primary key does not
  have to be selected. `update` and `delete` work after `select`; `create`
  and `createMany` are compile errors there. `Relation(S, G)` is now
  `RelationOf(S, G, S.Tuple)`, and `RelationOf` is exported along with
  `Project`. A dataset with `supports.projection` must declare
  `readProjected(query, comptime P, allocator) ![]P` (the memory adapter and
  `zom.file` datasets do); for any other dataset zom reads whole tuples and
  maps them down. `zom.lint` checks `readProjected`. ([#33])
- Order by several fields. `order(field, direction)` now appends a sort key,
  so `.order(.role, .asc).order(.age, .desc)` is `ORDER BY role ASC, age
  DESC`, and `reorder(.{ .{ .role, .asc }, .{ .age, .desc } })` replaces them
  all (`reorder(.{})` clears them). At most `Query.max_orders = 4` keys: a
  fifth `order` panics naming the limit, and a `reorder` tuple that is too
  long is a compile error. The memory adapter sorts with the stable
  `std.mem.sort`, so rows tied on every key keep their insertion order.
  `zom.sql.compileSelect` renders every key. `zom.lint` checks multi-key
  orders under `order_on`. ([#32])
- Boolean groups. `whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })`
  AND-s an OR group, `whereNot(cond)` a negation, and `zom.any`, `zom.all`
  and `zom.not` nest inside either. Each condition is `.{ field, op, value }`,
  type-checked like `where`. The filter tree is stored flat in the query
  (`nodes`, at most `Query.max_nodes = 32`, indexing into `filters`), so
  copying a relation copies the whole tree. `Query.matches` now uses SQL's
  three-valued logic, exposed as `Query.truth(row) ?bool`: `NOT (age > 30)`
  doesn't match a null age. `zom.sql.compileSelect` renders the groups with
  parentheses. `zom.lint` checks them, and skips that check when
  `supports.or` is false. A condition that can't fit an empty query is a
  compile error, and running out of room at runtime panics, naming the
  limit. ([#31])
- Query ops `in`, `not_in`, `like`, `ilike`, `between`, `is_null` and
  `is_not_null`. `where(.id, .in, .{ 1, 2, 3 })` takes a tuple of
  comptime-known values (at most `Query.max_in = 64`, each type-checked),
  stored as a static array; `whereIn(.id, slice)` and `whereNotIn` take a
  runtime slice of the attribute's type, which the relation borrows.
  `where(.name, .like, "Ach%")` only compiles on string attributes;
  `where(.age, .between, .{ 18, 30 })` is inclusive; `where(.age, .is_null,
  {})`, with `eq null` / `neq null` kept as aliases (stored as
  `is_null` / `is_not_null`). `Query.matches` evaluates them all with SQL
  null semantics, and `like` (`zom.query.like`) handles `%`, `_` (one UTF-8
  character) and `\` escapes without regex, in O(n·m). Building a query
  still never allocates. `zom.lint` checks each op, skipping `in` and `like`
  when `supports.in` / `supports.like` is false. `Query` builds itself too
  (`Query.where`, `whereIn`, `whereNotIn`). ([#30])
- `zom_yaml.Gateway` and `zom_yaml.WritableGateway`, with the same structure
  as zom-csv. `Config.path` is one YAML file mapping every dataset name to
  its records (rom-yaml's layout), or a directory of `<name>.yaml` files,
  each a bare sequence. Each dataset is loaded into a `zom.memory.Store(S)`
  on first use. Every record's keys are checked against the schema: a
  missing required key or an unknown one (unless `unknown_keys = .ignore`)
  is `error.SchemaMismatch`, and the message names the file, the line, the
  dataset, the 0-based list index and every bad key, as in
  `data.yaml:4: users[1]: missing key "name"`. Values decode through
  `zom.codec`, and errors read `data.yaml:6: users[1].age: "old" is not an
  integer from 0 to 255`. YAML null on a non-optional field is
  `error.UnexpectedNull`. On an optional field it wins over the field's
  default. `WritableGateway.sync()` writes records with keys in schema order
  and null as `~`. It quotes strings that other YAML readers would type
  (`"123"`, `"yes"`) and anything that can't be written plain. A
  single-file sync re-reads the file and keeps the other datasets as they
  are, in order and with their quoting. Comments are not kept.
  `writeRecords` and `writeDataset` write the same format. ([#27])
- `zom.file`, which zom-csv and zom-yaml now share:
  `Gateway(Format, mode)` and `FileDataset(S, Format, mode)` hold the file
  lookup, size limit and BOM handling, lazy per-dataset loading, the
  read-only and writable dataset types, the dirty flag and the atomic
  `sync`. A format supplies `name`, `extension`, `layout` (`.one_per_file`
  or `.all_in_file`), `Config`, `WriteError`, `load`, `dump` and optionally
  `State(S)`. Missing or mistyped declarations are listed in one compile
  error. `zom.file.Diagnostic` (with `list` for several problems in one
  message) and `zom.file.Unknown` replace the CSV-only versions;
  `zom_csv.Diagnostic` and `zom_csv.UnknownColumns` are now aliases of
  them, so zom-csv's API and messages are unchanged. ([#27])
- `yaml.writeScalar(writer, value, style)`, which writes a key or value
  that the parser reads back as the same bytes. `yaml.Field.quoted` says
  whether a value was quoted. ([#27])
- `zom.codec.Diagnostic.formatProblem`, the message without the
  `row:column (field)` prefix, for adapters that name the place their own
  way. ([#27])

- `zom-yaml` (`adapters/yaml`), starting with `yaml.parseDatasets` and
  `yaml.parseRecords`. They parse a documented subset of YAML: a mapping
  from dataset name to a block sequence of flat records, or one bare
  sequence. Every record field is a key mapped to scalar text, or `null`
  for `~`, `null`, `Null`, `NULL` and an empty value; `zom.codec` decodes
  the text. Scalars may be plain, `'single'` (with `''`) or `"double"`
  (with every YAML escape, including `\xXX`, `\uXXXX` and `\UXXXXXXXX`).
  Comments, blank lines, CRLF, a BOM and a leading `---` are accepted.
  `users: []` and `users:` with no items are empty datasets. Anchors,
  aliases, tags, block scalars, flow collections, nested values, complex
  keys, directives and multiple documents fail with
  `error.UnsupportedYaml`. A tab in indentation fails with
  `error.TabIndentation`, and misaligned lines with `error.BadIndentation`.
  Other errors are `UnterminatedQuote`, `InvalidEscape`, `DuplicateKey` and
  `InvalidSyntax`. A `yaml.Diagnostic` gives the line and column and formats
  as `2:6: unsupported YAML: an anchor (&name)`. Values without escapes
  borrow the input. Everything else lives in an arena that the result owns.
  This is our own parser, not kubkon/zig-yaml (findings in [#26]).
  `zig build test-adapters` now runs it too. ([#26])
- `zom_csv.WritableGateway`, the writable twin of `zom_csv.Gateway`. Its
  datasets add `insert`, `insertMany`, `update` and `delete`, which change
  the in-memory store and mark the dataset dirty. `sync()`, on a dataset or
  on the gateway for every dirty one, writes the header and rows to
  `<name>.csv.tmp`, flushes, fsyncs, closes it and renames it over
  `<name>.csv`. On any error the temp file is deleted, the original is left
  byte-for-byte unchanged and the dataset stays dirty. Columns keep the
  order of the header read at load time, and fields that header lacked
  follow in schema order. A new file uses schema order. The file keeps its
  permissions. A missing file is an empty dataset, created by the first
  sync after a write. Unknown columns are rejected even with
  `unknown_columns = .ignore`, because sync would drop them. `deinit` does
  not sync. New `Config.line_ending` (default `"\n"`). `writeTable` now
  reports a full row buffer as `error.OutOfMemory`, not
  `error.WriteFailed`. ([#25])
- `zom-csv`: `csv.Reader` and `csv.writeRow`, an RFC 4180 CSV reader and
  writer. The reader takes the whole file as `[]const u8` and yields rows
  (`while (try reader.next()) |row|`). It handles a configurable separator,
  `\n` and `\r\n` line endings, an optional final line break, and quoted
  cells holding separators, line breaks and `""` escapes. A blank line is a
  zero-cell row. Cells are sub-slices of the input, except cells with `""`
  escapes, which are unescaped into an arena reset on every `next()`. A row
  of up to 64 cells with no escapes makes no allocation. Errors are
  `error.UnterminatedQuote` and `error.UnexpectedQuote`, with the line and
  column in a `csv.Diagnostic` (`3:7: unterminated quote`). `writeRow`
  quotes a cell only when it holds the separator, `"`, `\r` or `\n` (or is
  the only cell and is empty), and doubles inner quotes. ([#23])
- `zom.codec.encodeField(writer, value, opts)` and `encodeRow(writer, T,
  row, opts, sep)`, the inverse of `decodeField`/`decodeRow`, for CSV sync
  and YAML writing. They write integers as `{d}`, floats as the shortest text
  that parses back to the same bits (decimal when `1e-6 <= abs(x) < 1e21`,
  scientific such as `1e300` otherwise), bools as `true`/`false`, enums as
  tag names, strings unchanged and `null` as `Options.null_text`. When
  `null_text` is `null` they fail with `error.NullNotRepresentable`. Nothing
  is quoted, because quoting is the format writer's job. ([#22])
- `zom.codec`, which decodes text cells (CSV, YAML scalars, SQL text
  results) into tuple field types. `decodeField(F, text, opts)` handles
  integers, floats, bools (`true`/`false`/`1`/`0`/`t`/`f`, any case), enums,
  optionals and `[]const u8`, which borrows `text`. `decodeRow(T, cells,
  opts, diag)` builds a whole tuple, with cells in field order or placed by
  `Options.columns`. A missing cell takes the field's default, else `null`,
  else fails with `error.MissingField`. `Options.null_text` (default `""`)
  means null, and a non-optional field given it fails with
  `error.UnexpectedNull`. Whitespace is never trimmed. On error, a
  `Diagnostic` records row, column, field and text, and formats as
  `14:3 (age): "abc" is not an integer from 0 to 255`. ([#21])
- The `adapters/<name>/` package layout, with `adapters/csv` (`zom-csv`) as
  the first, still a stub gateway. Each adapter has its own `build.zig.zon`
  depending on zom through `.path = "../.."`. `zig build test-adapters` runs
  every adapter's `zig build test`, and `zig build test` runs it too.
  `adapters/` is outside zom's `.paths`, so it doesn't affect zom's package
  hash. README: "Writing an adapter". ([#20])
- `zom.lint.run(G, Factory)`, the adapter conformance suite (like rom's
  `ROM::Lint`). It seeds its own schema, `zom.lint.Users`, through the
  factory's `seed` or the dataset's `insertMany`/`insert`, and checks reads,
  every filter op, `null` semantics, ordering with nulls, `limit`/`offset`
  edge cases, `one`, and that `count` matches the rows read. Failures name
  the check and case; checks needing a missing capability or `zom.Supports`
  feature are skipped with a message. The memory adapter passes it. ([#17])
- `zom.lint` write checks: `insert`, `createMany` (with `insertMany` or the
  `insert` fallback), `update` and `delete`, including
  `error.DuplicatePrimaryKey`, `error.ValueOutOfRange`, failed writes changing
  nothing, and strings being copied on every write. A factory can declare
  `insert_many_on_duplicate: zom.lint.OnDuplicate` to say what a failed
  batch leaves stored. `zom.lint.expectSharedError` checks that an adapter
  uses the shared names from `zom.adapter.Error`. Each check is skipped when
  the capability is missing. ([#18])
- `zig build compile-errors` checks that each file in `tests/compile_errors/`
  fails to compile with the message on its `// expect:` line. `zig build test`
  runs it too. ([#11]) A case can start with several `// expect:` lines, and
  each one must appear in stderr. ([#12])
- `zom.Adapter(G)` checks a gateway against the v1 adapter contract (plan.md
  section 3.1), signatures included, and reports every problem in one compile
  error. `capabilities(S)` and `has(S, cap)` say which optional declarations
  it has, as `zom.Capability` values: `writable` (`insert`), `batch_insert`
  (`insertMany`), `updatable` (`update`), `deletable` (`delete`) and
  `transaction`. `zom.Relation` exposes it as `Relation.Adapter`. ([#12])
- `zom.Supports` lists the query features a dataset can evaluate (`or`, `in`,
  `like`, `order_on`, `offset`, `projection`, `join`). A dataset declares
  `pub const supports: zom.Supports`; `Adapter(G).supports(S)` returns it,
  or the defaults when there is none. The memory adapter declares `.all`.
  Relations do not check it yet. ([#13])
- `zom.adapter.Error` names the errors every adapter must use for the same
  condition: `DuplicatePrimaryKey`, `ValueOutOfRange`, `NotFound`,
  `ReadOnly` and `ConnectionFailed`. ([#13])
- `Adapter(G).readOnly(S)` is true when the dataset has no `insert`,
  `insertMany`, `update` or `delete`. ([#14])
- `Relation.createMany(tuples)` returns a `changeset.CreateMany`, whose
  `commit()` returns `!usize`, the rows inserted. It calls the dataset's
  `insertMany` when there is one, else loops over `insert`, stopping at the
  first error with the earlier rows still stored; with neither it is a
  compile error. `Adapter(G).requireAny(S, caps, method)` backs that
  check. ([#15])
- `zom.memory` datasets have `insertMany` (`.batch_insert`), which stores
  all or nothing: a duplicate key, against the table or inside the batch, or
  running out of memory stores no rows. ([#15])
- `zom.memory.Store(S)` is the memory adapter's row engine, usable without
  a gateway so file adapters can wrap it. Besides the dataset methods it has
  `rows()` (every row, for writing a file back), `load(row)` and
  `loadMany(rows)` (insert without the primary-key check, for trusted bulk
  loads) and `clear()` (drops every row and resets the string arena).
  `memory.Gateway.Dataset(S)` is `Store(S)`. ([#16])
- `zom.Container(.{ .gateways = ..., .relations = ... })`, like
  `ROM.container`: declares gateways and the relations over them once, and
  generates `Gateways`, `Relations` and `Config` structs. `app.init(allocator,
  config)` initialises the gateways in declaration order and builds the
  relations, deinitialising the gateways already initialised if anything
  fails; `deinit` runs in reverse. `init` fills the container in place, so it
  must not be moved before `deinit`. An unknown gateway name or an invalid
  gateway is a compile error. ([#19])

### Changed (breaking)

- zom-pg errors are a closed set, `zom_pg.Gateway.Error`. `42P01`
  (undefined_table) is now `error.NotFound`, and every other Postgres or
  pg.zig error is `error.Database` (it was `error.PG`, or pg.zig's own
  error). The server's error is available through
  `zom_pg.Gateway.lastError()`, a per-thread `zom_pg.ServerError` with the
  SQLSTATE, message and constraint. Every unique violation, on the primary
  key or not, is still `error.DuplicatePrimaryKey`. ([#38])

- A dataset that sets `supports.projection = true` (for example with
  `zom.Supports.all`) must now declare `readProjected`, or the adapter
  contract check fails naming it. Set `projection = false` to keep the old
  behaviour: `select` then maps whole tuples down. ([#33])
- `Relation.order` (and the new `Query.order`) appends a sort key instead of
  replacing the order: use `reorder` to replace. `Query.order: ?Order` is now
  `orders` / `order_count`, read through `orderSlice()` and written with
  `addOrder`. `Query.lessThan` takes the order list (`[]const Order`), for
  `std.mem.sort(T, rows, query.orderSlice(), Q.lessThan)`; `Query.orderBy`
  compares on one key. ([#32])
- `Query.Filter` is `{ field, op, operand }`, where `operand` is a
  `zom.query.Operand` (`none`, `one`, `many`, `range`), replacing `value`.
  A hand-built filter becomes `.operand = .{ .one = v }`. ([#30])
- The `op` argument of `where` is now `comptime`, since it decides what the
  value must be. A runtime `zom.Op` no longer compiles. ([#30])
- `sql.compileSelect` returns `error.UnsupportedFilter` for the new ops
  until zom-sql renders them (#35). ([#30])
- A gateway must declare `adapter_name`, `Config`, `init(allocator, Config)`
  and `deinit` as well as `Dataset` and `dataset`. ([#12])
- `zom.memory.Gateway.init` takes a `Config` (an empty struct for now):
  write `zom.memory.Gateway.init(allocator, .{})`. ([#12])
- A dataset's `insert`, `update` and `delete` are optional. Without one,
  `create(...).commit()`, `update().commit()` or `delete()` is a compile error
  naming the adapter, instead of a missing-declaration error from
  `zom.Relation`. ([#12])
- `Relation.create` and `Relation.update` check the capability themselves,
  so the error points at the call, not at `commit`. `commit` still checks
  for a changeset built by hand. The message now names the relation and the
  capability: ``zom: adapter 'csv' is read-only for relation 'users': `create`
  needs the `writable` capability (dataset has no `insert`)``. ([#14])
- `zom.memory.MemoryDataset(S)` is renamed `zom.memory.Store(S)`. ([#16])
- A dataset's `count` returns the number of rows `read` would return, so
  `limit` and `offset` now apply (they were ignored). `users.limit(2).count()`
  is at most 2. ([#17])

## [0.2.0] - 2026-10-30

Phase 0 of [plan.md](plan.md): the core is tidied and its public API is
frozen. Adapters written from Phase 1 on build against this release. The
API is listed in the README under [API (v0.2)](docs/api.md#api-v02).

### Changed (breaking)

- `count` and `delete` are fallible in the dataset contract and on
  `Relation`: both now return `!usize` instead of `usize`, because real
  adapters do I/O for them. Call sites need `try users.count()` and
  `try users.where(...).delete()`. A custom dataset must declare
  `count(query) !usize` and `delete(query) !usize`. ([#8])
- `zom.Value` has a new `uint: u64` variant. Code that switches over
  `Value` exhaustively must handle it. ([#2])

### Fixed

- `u64` values above `maxInt(i64)` no longer crash in `toValue`. They are
  stored as `.uint`, and compare correctly against `.int` and `.float`.
  Integers wider than 64 bits are a compile error until `u128` lands. ([#2])
- Every string slice type (not only `[]const u8`), such as `[:0]const u8`,
  `[]u8` and optional strings, is copied into the dataset's arena on insert
  and update, keeping any sentinel. A pointer-to-array attribute
  (`*const [N]u8`) is now a compile error asking for `[]const u8`. ([#3])
- Enum attributes sort and compare in declaration order, as Postgres ENUMs
  do, instead of alphabetically by tag name. ([#4])
- The memory adapter checks and copies every change before it writes, so an
  update that runs out of memory, hits a duplicate key or has a value out of
  range leaves every row as it was. ([#5])
- `LIMIT` and `OFFSET` up to `maxInt(usize)` no longer overflow the SQL
  compiler's format buffer. ([#6])
- The SQL compiler quotes the table and every column as an identifier
  (`"name"`, with `"` doubled), so reserved words and mixed-case names work.
  `zom.sql.writeIdent` is public for adapters that build their own SQL. ([#7])

### Added

- `CHANGELOG.md`, and `examples/readme.zig`, which compiles every README
  code block as part of `zig build test`. ([#10])

### Internal

- `src/tests.zig` is split by layer into `src/tests/` (relation, changeset,
  mapper, memory, sql). ([#9])

## [0.1.0]

First version: schemas, immutable relations, create and update changesets,
mappers with `combineMany`, the memory adapter and the SQL `SELECT` compiler.

[Unreleased]: https://github.com/kamalogudah/zom/compare/v0.17.1...HEAD
[0.17.1]: https://github.com/kamalogudah/zom/compare/v0.16.1...v0.17.1
[0.16.1]: https://github.com/kamalogudah/zom/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/kamalogudah/zom/releases/tag/v0.16.0
[0.2.0]: https://github.com/kamalogudah/zom/releases/tag/v0.2.0
[0.1.0]: https://github.com/kamalogudah/zom/commits/04a755a
[#2]: https://github.com/kamalogudah/zom/issues/2
[#3]: https://github.com/kamalogudah/zom/issues/3
[#4]: https://github.com/kamalogudah/zom/issues/4
[#5]: https://github.com/kamalogudah/zom/issues/5
[#6]: https://github.com/kamalogudah/zom/issues/6
[#7]: https://github.com/kamalogudah/zom/issues/7
[#8]: https://github.com/kamalogudah/zom/issues/8
[#9]: https://github.com/kamalogudah/zom/issues/9
[#10]: https://github.com/kamalogudah/zom/issues/10
[#11]: https://github.com/kamalogudah/zom/issues/11
[#12]: https://github.com/kamalogudah/zom/issues/12
[#13]: https://github.com/kamalogudah/zom/issues/13
[#14]: https://github.com/kamalogudah/zom/issues/14
[#15]: https://github.com/kamalogudah/zom/issues/15
[#16]: https://github.com/kamalogudah/zom/issues/16
[#17]: https://github.com/kamalogudah/zom/issues/17
[#18]: https://github.com/kamalogudah/zom/issues/18
[#19]: https://github.com/kamalogudah/zom/issues/19
[#20]: https://github.com/kamalogudah/zom/issues/20
[#21]: https://github.com/kamalogudah/zom/issues/21
[#22]: https://github.com/kamalogudah/zom/issues/22
[#23]: https://github.com/kamalogudah/zom/issues/23
[#25]: https://github.com/kamalogudah/zom/issues/25
[#26]: https://github.com/kamalogudah/zom/issues/26
[#27]: https://github.com/kamalogudah/zom/issues/27
[#30]: https://github.com/kamalogudah/zom/issues/30
[#31]: https://github.com/kamalogudah/zom/issues/31
[#32]: https://github.com/kamalogudah/zom/issues/32
[#33]: https://github.com/kamalogudah/zom/issues/33
[#34]: https://github.com/kamalogudah/zom/issues/34
[#35]: https://github.com/kamalogudah/zom/issues/35
[#36]: https://github.com/kamalogudah/zom/issues/36
[#37]: https://github.com/kamalogudah/zom/issues/37
[#38]: https://github.com/kamalogudah/zom/issues/38
[#39]: https://github.com/kamalogudah/zom/issues/39
[#40]: https://github.com/kamalogudah/zom/issues/40
[#41]: https://github.com/kamalogudah/zom/issues/41
[#46]: https://github.com/kamalogudah/zom/issues/46
[#48]: https://github.com/kamalogudah/zom/issues/48
[#49]: https://github.com/kamalogudah/zom/issues/49
[#50]: https://github.com/kamalogudah/zom/issues/50
[#51]: https://github.com/kamalogudah/zom/issues/51
[#52]: https://github.com/kamalogudah/zom/issues/52
[#53]: https://github.com/kamalogudah/zom/issues/53
[#54]: https://github.com/kamalogudah/zom/issues/54
[#55]: https://github.com/kamalogudah/zom/issues/55
[#56]: https://github.com/kamalogudah/zom/issues/56
[#57]: https://github.com/kamalogudah/zom/issues/57
[#58]: https://github.com/kamalogudah/zom/issues/58
