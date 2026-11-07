# zom-tigerbeetle

A [zom](../../README.md) gateway for [TigerBeetle](https://tigerbeetle.com),
on its C client (`tb_client`). TigerBeetle tests zom's adapter contract
hardest: two fixed schemas, 128-bit ids, immutable records, batched writes
and limited queries (plan.md, Phase 6).

**Status:** complete for Phase 6: inserts, reads, account history and
linked chains, tested against a TigerBeetle dev cluster in CI
(`.github/workflows/tigerbeetle.yml`).
[`examples/double_entry`](../../examples/double_entry/src/main.zig) opens
two accounts, posts transfers (a linked chain included) and reads the
balances back through zom relations and changesets only.

## What's supported, and what isn't

| zom | TigerBeetle | |
|---|---|---|
| `create`, `createMany` | `create_accounts` / `create_transfers`, batched | [Inserts](#inserts) |
| `relation.linked().add(..).commit()` | a chain of `flags.linked` events in one request | [Linked chains](#linked-chains) |
| `byPk`, `where(.id, ...)`, `whereIn(.id, ...)` | `lookup_accounts` / `lookup_transfers` | [Reads](#reads) |
| `where` `.eq` on `user_data_*`, `ledger`, `code`; `timestamp` ranges; `order(.timestamp, ...)`; `limit` | `query_accounts` / `query_transfers` | [Reads](#reads) |
| `count` | pages through the matches | [Reads](#reads) |
| `combine(.transfers)`, `combine(.balances)`, `belongsTo` | `get_account_transfers`, `get_account_balances`, `lookup_*` | [Account history](#account-history) |
| `update`, `delete` | none: records are immutable | compile error |
| `container.transaction` | none: no transactions | compile error, pointing to `linked()` |
| `offset`, other filters and orders | none: the cluster only filters and orders this much | compile error, or in memory with `allowFallback()` |
| `like`, `join`, projections, other schemas | none | compile error |

**Why.** TigerBeetle is a ledger, not a general database. Accounts and
transfers are its only two record types, with fixed fields. A record is
never changed or removed once created: a correction is a new transfer.
Atomicity comes from linked events in one request, not from a session that
can roll back. Queries go through a few indexes (`user_data_*`, `ledger`,
`code`, `timestamp`), and results come in `timestamp` order only.

**Strict and fallback.** A relation is strict by default: a query
TigerBeetle can't run in full is a compile error that names the call, so a
filter or order never quietly turns into a scan. `allowFallback()` on the
relation lets zom send TigerBeetle the part it can run and do the rest in
memory (`offset`, `.gt` on `amount`, `order(.amount, ...)`, ...). See
[Reads](#reads) for exactly what goes to the cluster.

## Schemas

The schemas are fixed, and they use the client's own structs, not copies:

```zig
pub const Account = zom.Schema(tb.Account, "accounts", .id, .{
    .associations = struct {
        pub const transfers = zom.customAssociation(Transfer, .account_transfers, .many);
        pub const balances = zom.hasMany(AccountBalance, .account_id);
    },
});
pub const Transfer = zom.Schema(tb.Transfer, "transfers", .id, .{
    .associations = struct {
        pub const debit_account = zom.belongsTo(Account, .debit_account_id);
        pub const credit_account = zom.belongsTo(Account, .credit_account_id);
    },
});
// Read only: see "Account history".
pub const AccountBalance = zom.Schema(tb.AccountBalance, "account_balances", null, .{ ... });
```

`tb.Account` and `tb.Transfer` are `tb_account_t` and `tb_transfer_t` from
`tb_client.h`. They are `extern struct`s of 128 bytes holding only plain
integers, with every field defaulting to 0:

| Field | Type |
|---|---|
| `id`, amounts / balances, `debit_account_id`, `credit_account_id`, `pending_id`, `user_data_128` | `u128` (zom's `Value.uint128`) |
| `user_data_64`, `timestamp` | `u64` |
| `user_data_32`, `ledger`, `timeout` (transfers), `reserved` (accounts) | `u32` |
| `code`, `flags` | `u16` |

In the C header `flags` is a plain `u16`, not a packed struct, so zom needs
no special support for it. For named bits, use `tb.AccountFlags` and
`tb.TransferFlags`, which are `packed struct(u16)`s of bools:

```zig
var account: tb.Account = .{ .id = 1, .ledger = 700, .code = 10 };
account.flags = tb.AccountFlags.bits(.{ .history = true });
const flags = tb.AccountFlags.of(account); // flags.history == true
```

A test checks that each flag's bit matches the header's `TB_*_FLAGS`
constant. The struct sizes, alignments and `extern` layout are asserted at
compile time, so a newer header that changes them won't build.

`Gateway.Dataset` also accepts a `zom.Schema` of your own over `tb.Account`
or `tb.Transfer` keyed by `.id`, for example to add plugins or
associations. It shares the fixed schema's dataset. Any other struct is a
compile error.

No `update`, no `delete`, no `transaction`: TigerBeetle records are
immutable, so `relation.update()` and `relation.delete()` don't compile
(`zom: adapter 'tigerbeetle' does not support `update` for relation
'transfers'...`). Linked event chains take the place of transactions:
see [Linked chains](#linked-chains).

## Inserts

```zig
const accounts = try zom.Relation(zom_tigerbeetle.Account, zom_tigerbeetle.Gateway).init(&gateway);
const transfers = try zom.Relation(zom_tigerbeetle.Transfer, zom_tigerbeetle.Gateway).init(&gateway);

const stored = try accounts.create(.{ .id = 1, .ledger = 700, .code = 10 }).commit();
// stored.timestamp is the cluster's.

_ = transfers.create(.{ .id = 7, .debit_account_id = 1, .credit_account_id = 2, .amount = 50, .ledger = 700, .code = 1 }).commit() catch |err| switch (err) {
    error.ExceedsCredits => {}, // account 1 has debits_must_not_exceed_credits
    error.DuplicatePrimaryKey => {}, // transfer 7 exists
    else => return err,
};

const n = try transfers.createMany(rows).commit(); // any number of rows
```

`create` sends one `create_accounts` / `create_transfers` event and
`createMany` sends batches. Each event's result code becomes an error:

- `.created` is success.
- `.exists` and the `.exists_with_different_*` codes are
  `error.DuplicatePrimaryKey`, zom's name for an id that's taken.
- Every other code is the error of the same name: `.exceeds_credits` is
  `error.ExceedsCredits`, `.linked_event_failed` is
  `error.LinkedEventFailed`, and so on.

The codes are the enums `zom_tigerbeetle.results.CreateAccountResult` and
`CreateTransferResult`, generated at compile time from the header's
`TB_CREATE_*` constants, so they always match the linked client. Zig can't
generate error sets, so `CreateAccountError` and `CreateTransferError` are
written out in `results.zig`. A code that has no error there is a compile
error, so a client upgrade can't add a code that goes unmapped. A test
checks that no error is left over from a removed code. A code the client
doesn't know (from a newer cluster) is `error.UnknownResult`.

### Batches

TigerBeetle applies each event of a request on its own, except for linked
chains, so a batch is not all or nothing. `createMany` sends every batch,
and the rows that can be created are. If any row fails, it returns that
row's error (the first one, skipping `LinkedEventFailed`, which only says
that another event in its chain failed), and the count is lost. To find out
which rows failed, call the dataset directly:

```zig
const dataset = try gateway.dataset(zom_tigerbeetle.Transfer);
const failed = try dataset.insertManyResults(rows, allocator);
defer allocator.free(failed);
for (failed) |f| std.log.info("row {d}: {t}", .{ f.index, f.code }); // e.g. .exceeds_credits
```

`failed` lists every row that wasn't created, in order. An empty result
means all of them were.

A request holds at most a cluster-set number of events. That number is
8189 by default and 253 for a `--development` cluster. `tb_client.h`
doesn't expose it, so the gateway learns it. It starts at
`Config.batch_max` (8189). The client refuses a request that is too big
before sending it, so nothing is applied, and the gateway retries with a
smaller batch. It searches between the largest batch that worked and the
smallest that was refused, and keeps the size it settles on. On a
development cluster the first `createMany` makes about a dozen refused
tries, all local, and then sends batches of 253. Set `batch_max` to the
cluster's limit to skip the search. `gateway.batchLimit()` is the current
size, and `gateway.requestCount()` counts the requests sent.

Batches are never cut inside a linked chain (events with `flags.linked`,
and the event that closes the chain): the batch ends before the chain
instead. A chain longer than the limit can't be sent, so it is
`error.LinkedChainTooLong`. If the chain is longer than `batch_max`, that
is caught before anything is sent.

A failed transfer's id stays taken. Sending it again gives
`error.IdAlreadyFailed`, not a second try.

## Linked chains

TigerBeetle has no transactions. Its atomicity is a chain of events in one
request, `flags.linked` set on every event but the last: if one fails, none
is applied. `relation.linked()` builds one:

```zig
_ = try transfers.linked()
    .add(.{ .id = 1, .debit_account_id = a, .credit_account_id = b, .amount = 100, .ledger = 700, .code = 1 })
    .add(.{ .id = 2, .debit_account_id = b, .credit_account_id = c, .amount = 100, .ledger = 700, .code = 1 })
    .commit(); // both, or neither
```

- **Flags.** Give the events without `flags.linked`. `commit` sets it on a
  copy of every event but the last, clears it on the last, and leaves the
  other flags (`pending`, `history`, ...) alone. `prepared(&buf)` returns
  the batch `commit` would send.
- **One request.** The whole chain goes in one `create_transfers` /
  `create_accounts`. A chain longer than the cluster's batch limit is
  `error.LinkedChainTooLong`, and nothing is sent.
- **Capacity.** A chain holds up to `zom_tigerbeetle.linked.linked_capacity`
  (32) events, kept in the changeset value (Tiger Style: no allocation).
  Adding more is a bug, and asserts.
- **Errors.** Every event but the one at fault gets `linked_event_failed`.
  `commit` returns the cause's own error (`error.CreditAccountNotFound`,
  `error.ExceedsCredits`, ...), and `reportTo(&failure)` says which event
  it was:

  ```zig
  var failure: Transfers.Linked().Failure = undefined;
  _ = transfers.linked().add(t1).add(t2).reportTo(&failure).commit() catch |err| {
      // err == error.CreditAccountNotFound, failure.index == 1,
      // failure.code == .credit_account_not_found
  };
  ```

- **Spent ids.** A transient error (an account not found, an overdraft,
  ...) spends the failing event's id: TigerBeetle answers that id with
  `id_already_failed` from then on, so a fixed retry needs a new id. The
  events that only got `linked_event_failed` keep theirs.

`container.transaction(.tb, ...)` doesn't compile, and its message points
here (`...does not support transactions: ...; TigerBeetle's all-or-nothing
writes are linked event chains: `relation.linked().add(a).add(b).commit()``).

## Reads

```zig
const one = try accounts.byPk(id).one(allocator); // lookup_accounts
const some = try accounts.whereIn(.id, ids).toSlice(allocator); // lookup_accounts, up to 64 ids
const newest = try transfers // query_transfers
    .where(.ledger, .eq, 700)
    .where(.user_data_128, .eq, order_id)
    .where(.timestamp, .gte, since)
    .order(.timestamp, .desc)
    .limit(50)
    .toSlice(allocator);
```

| Relation | TigerBeetle |
|---|---|
| `byPk(id)`, `where(.id, .eq, id)`, `where(.id, .in, ids)` / `whereIn` | `lookup_accounts` / `lookup_transfers`, one request |
| `.eq` on `user_data_128`, `user_data_64`, `user_data_32`, `ledger`, `code` | `query_accounts` / `query_transfers`, one `QueryFilter` |
| `timestamp` by `eq`, `lt`, `lte`, `gt`, `gte`, `between` | the filter's `timestamp_min` / `timestamp_max` |
| `.order(.timestamp, .asc)` / `.desc` | the filter's `reversed` flag |
| `.limit(n)` | the filter's `limit`, in pages of up to 8189 |
| anything else, and `offset` | a compile error, or in memory with `allowFallback()` |

The datasets declare this to zom: `supports` (`in`, and no `offset`),
`filterable(field, op)` and `orderable(field)`. A strict relation that uses
anything else doesn't compile, and the message names the call:

```
zom: adapter 'tigerbeetle' cannot evaluate `where(.amount, .gt, ...)` on relation 'transfers':
its dataset's `filterable` rejects `.gt` on 'amount'; call `allowFallback()` on the relation
to evaluate it in memory instead
```

With `allowFallback()`, zom sends the part TigerBeetle can do and runs the
rest in memory. TigerBeetle orders only by `timestamp`, so a `.fallback`
`order(.amount, .desc)` reads every matching row and sorts them.

- **An id filter wins.** With `where(.id, ...)` the read is a lookup, and
  any other filter, order and limit is applied to the (at most 64) rows it
  returns. Without an order, they come in the order the ids were given.
- **Every row is checked.** The gateway checks each row the cluster
  returns against the whole query, so a filter a `QueryFilter` can't hold
  is still right, just slower. In a `QueryFilter`, 0 means "no filter", so
  `where(.user_data_64, .eq, 0)` reads rows with any `user_data_64` and
  keeps the zeros. A query that can't match anything, such as `ledger = 1
  AND ledger = 2` or an empty timestamp range, sends no request at all.
- **Paging.** A reply holds at most 8189 records, on any cluster:
  `--development` lowers the request limit, not the reply limit. A longer
  read sends the next page from just past the last timestamp. A page
  shorter than asked for is the last one.
- **`offset`** isn't supported. TigerBeetle can only start from a
  timestamp, so skipping rows means reading them, and `.fallback` makes
  that visible. To page, filter on the timestamp of the last row you read:
  `where(.timestamp, .lt, last.timestamp).order(.timestamp, .desc).limit(n)`.
- **`count`.** TigerBeetle has no count operation, so `count` pages
  through the matching rows and counts them without keeping them. It costs
  as many requests as reading them.
- **Bounded.** A read or count that fetches `Config.scan_max` records (2^20
  by default) without finishing fails with `error.ScanLimitExceeded`. A
  read with a limit on filters TigerBeetle evaluates fetches at most that
  limit. A count, or a read without a limit, fetches every match.
- **Atomicity.** Pages are separate requests. Rows created between them
  can show up in a later page, as TigerBeetle's docs warn for lookups too.

## Account history

An account's transfers and its balance after each of them come through
`combine`:

```zig
const accounts = try zom.Relation(zom_tigerbeetle.Account, zom_tigerbeetle.Gateway).init(&gateway);
const transfers = try zom.Relation(zom_tigerbeetle.Transfer, zom_tigerbeetle.Gateway).init(&gateway);
const balances = try zom.Relation(zom_tigerbeetle.AccountBalance, zom_tigerbeetle.Gateway).init(&gateway);

const History = struct {
    id: u128,
    transfers: []const zom_tigerbeetle.tb.Transfer,
    balances: []const zom_tigerbeetle.tb.AccountBalance,
};
var with_transfers = try accounts.byPk(id)
    .combine(.transfers, transfers.where(.code, .eq, 1).order(.timestamp, .desc))
    .mapTo(struct { id: u128, transfers: []const zom_tigerbeetle.tb.Transfer }, allocator);
defer with_transfers.deinit();
var with_balances = try accounts.byPk(id).combine(.balances, balances).mapTo(struct {
    id: u128,
    balances: []const zom_tigerbeetle.tb.AccountBalance,
}, allocator);
defer with_balances.deinit();
```

**Transfers.** A transfer belongs to an account as its debit *or* credit
account, which no single foreign key expresses, so `Account.transfers` is a
`zom.customAssociation`. The transfers dataset declares `loadAssociation`
(zom's hook for a dataset that loads associations itself), and sends one
`get_account_transfers` per account, both sides. Each account gets every
transfer it is on, so a transfer between two of the combined accounts is in
both slices. The combined relation's `eq` on `user_data_128/64/32` and
`code`, its timestamp range, and `order(.timestamp, .desc)` go into the
`AccountFilter`. Anything else (such as `ledger`, which the filter doesn't
have) is checked on the rows, as for any read. Pages and `scan_max` work as
in [Reads](#reads), per account.

**Balances.** `AccountBalance` is a read-only view. Its rows,
`tb.AccountBalance`, are `tb_account_balance_t` (the four balances just
after the transfer with that `timestamp`) plus the `account_id` the request
named. Only accounts created with `flags.history` have any.
`Account.balances` is a plain `hasMany` on `account_id`, so zom's own
combine reads it with `whereIn(.account_id, keys)`. The balance dataset
sends one `get_account_balances` per id. It can be read directly too:

```zig
const latest = try balances.where(.account_id, .eq, id).order(.timestamp, .desc).first(allocator);
```

A read needs an `account_id` filter (`eq` or `in`). Without one,
TigerBeetle has nothing to ask for, so it fails with
`error.AccountIdRequired`.

The view has no primary key (it is declared with `null`). A row is unique
per `account_id` and `timestamp`, but `timestamp` alone is not unique,
because a transfer moves both its accounts' balances, so two rows share it.
So `balances.byPk(...)` is a compile error, as is a `belongsTo` pointing at
the view. One row is:

```zig
const after = try balances.where(.account_id, .eq, id).where(.timestamp, .eq, transfer.timestamp).first(allocator);
```

A schema of your own over `tb.AccountBalance` must be declared without a
primary key too: keying it by `.timestamp` is a compile error. `timestamp`
ranges and order are the filter's. Several accounts with an order, or
filters on the balances themselves (with `allowFallback()`), are done in
memory.

**Other associations.** The record datasets load every association into
them with the request that fits, chosen at compile time:

| Association into transfers / accounts | Request |
|---|---|
| `Account.transfers` | `get_account_transfers`, debits and credits |
| `hasMany` on `debit_account_id` / `credit_account_id` (your own schema) | `get_account_transfers`, that side only |
| `belongsTo`, e.g. `Transfer.debit_account` | `lookup_*`, 64 ids at a time |
| `hasMany` on `user_data_128/64/32`, `ledger` or `code` | one `query_*` per key |
| anything else, e.g. `hasMany` on `pending_id` | a compile error |

As with any combine, a `limit` on the combined relation pages each
account's rows: `accounts.combine(.transfers, transfers.order(.timestamp, .desc).limit(10))`
gives every account its latest ten transfers. Every matching transfer is
read, then each account keeps its first ten (`offset` is not supported by
this adapter's datasets).

### zom.lint

zom.lint defines its own schema (`lint_users`, with a string `name`), and
TigerBeetle's two schemas are fixed, so `zom.lint.run` can't be called
here. Instead, a live test (`lint read checks` in gateway.zig) seeds six
accounts. It runs the kinds of queries lint's read checks use on them:
every supported op, `in`, ranges, `whereAny` / `whereNot`, orders, limit
and offset, strict and `.fallback`. It compares each result and count with
the same query evaluated in memory on the seeded rows. Lint's order checks
(by `name`, `age`, `id`) have no counterpart, because TigerBeetle orders by
`timestamp` only. Lint's insert checks have their own live tests.

Lint's update and delete checks can't apply. The test reports them the
way `run` reports a skipped check, from `zom.lint.capabilitySkips`, so the
log says why:

```
zom.lint [tigerbeetle]: skipped on 'accounts': update: count, error.DuplicatePrimaryKey, error.ValueOutOfRange (dataset has no `updatable` capability)
zom.lint [tigerbeetle]: skipped on 'accounts': delete: count, rows gone (dataset has no `deletable` capability)
zom.lint [tigerbeetle]: skipped on 'transfers': update: ...
zom.lint [tigerbeetle]: skipped on 'transfers': delete: ...
```

It also asserts that these two are the only checks skipped for lack of a
capability.

## Threads

The client runs its own thread for all network I/O. zom's calls are
synchronous, so each request (`create`, `createMany`, or a read's page) blocks the calling
task on a `std.Io.Event` until the client's thread delivers the reply. The
wait can't be cancelled, because the client writes into the request until
it completes. One gateway can be shared by several threads. Their requests
are independent, and the client batches requests queued at the same time.

## Setup

zom-tigerbeetle is the `zom_tigerbeetle` module of the zom package. Its
client library is a lazy dependency, so it only exists when asked for:

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize, .tigerbeetle = true });
exe.root_module.addImport("zom_tigerbeetle", dep.module("zom_tigerbeetle"));
```

In a checkout of zom, `-Dtigerbeetle` is on by default.
`zig build test-tigerbeetle` runs this module's tests and the cases in
`tests/compile_errors` that must not compile. The tests that talk to a
cluster are skipped unless `ZOM_TB_ADDRESSES` is set. They create fresh
random ids on every run, so they can be rerun against the same cluster, and
they pass on a `--development` cluster and on a production-config one:

```sh
tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development 0_0.tigerbeetle
tigerbeetle start --addresses=3000 --development 0_0.tigerbeetle &
ZOM_TB_ADDRESSES=3000 zig build test-tigerbeetle
```

```zig
var gateway = try zom_tigerbeetle.Gateway.init(allocator, .{
    .io = io,
    .cluster_id = 0,
    .addresses = "3000", // or "10.0.0.1:3000,10.0.0.2:3000,10.0.0.3:3000"
});
defer gateway.deinit();
```

### CI

`.github/workflows/tigerbeetle.yml` downloads the `tigerbeetle` release
binary (pinned to the client's release, checked by SHA-256), formats a
single-replica `--development` data file, starts it, and runs
`zig build test-tigerbeetle` with `ZOM_TB_ADDRESSES` set. A skipped cluster
test fails the job, since it means the address didn't reach the tests,
and so does a missing lint skip line for update or delete. Then it runs
`examples/double_entry` (`zig build test` checks its output, `zig build
run` prints it).

`init` starts the client, which connects in the background. An unreachable
cluster shows up on the first request, not in `init`. `init` only fails on
bad addresses (`error.InvalidAddress`), on OS resources, or when out of
memory.

## How the client is fetched (the dependency decision)

zom builds with Zig 0.16. There were three ways to reach TigerBeetle:

1. **A source dependency on the tigerbeetle repo, importing its Zig
   client.** Ruled out. TigerBeetle's releases pin their own Zig: the
   `0.17.9` and `0.17.10` tags use Zig 0.14.1, and only unreleased `main`
   was on 0.16.0 when this was decided (2026-11). The repo also isn't set up
   to be a dependency. It has no `build.zig.zon`, its `build.zig` exports
   only `stdx` (the client lives in the internal `vsr` module), and
   `build()` asserts a git commit, which a fetched tarball doesn't have.
2. **The C client through translate-c and a static library.** Chosen. The C
   ABI doesn't depend on which Zig built the library, so a `libtb_client`
   built by TigerBeetle's Zig links into a 0.16 program.
3. **The binary protocol, implemented in zom.** Not pursued. It would mean
   reimplementing VSR client sessions, and tracking TigerBeetle's
   wire-format changes forever.

TigerBeetle's GitHub releases don't ship `libtb_client`, but
[tigerbeetle-go](https://github.com/tigerbeetle/tigerbeetle-go) vendors it
in `native/` for every release tag. That gives one header, `tb_client.h`,
and these libraries:

| Target | Library |
|---|---|
| x86_64-linux, aarch64-linux | `libtb_client_<arch>-linux.a` |
| x86_64-macos, aarch64-macos | `libtb_client_<arch>-macos.a` |
| x86_64-windows | `tb_client_x86_64-windows.lib` (plus `ws2_32`, `ntdll`) |

zom's `build.zig.zon` pins that tarball (1.3 MB) at tag `v0.17.9`, and the
tag sets the client release. zom's `build.zig` translates the header with
the built-in `b.addTranslateC` (no translate-c package needed) and links
the library for the target. Any other target gets a build error that names
the supported ones. The module links libc, because the library uses libc
for its thread and its I/O.

This was checked before any adapter code was written: Zig 0.16.0 with the
`v0.17.9` library against a `tigerbeetle 0.17.9` dev server ran
`create_accounts`, then `lookup_accounts` with ids above `maxInt(u64)`.

To move to another client release, pick the tag that matches your cluster
(a client must be within the release range the cluster accepts):

```sh
# from the repo root; then put `.lazy = true` back on the tigerbeetle_go entry
zig fetch --save=tigerbeetle_go https://github.com/tigerbeetle/tigerbeetle-go/archive/refs/tags/v<release>.tar.gz
```

If TigerBeetle releases on Zig 0.16 later, option 1 could replace this. The
schemas would stay the same, because the Zig client's `Account` and
`Transfer` have the same layout. Only `flags` would become the packed
struct.
