# Writing and checking adapters

The adapters zom ships, and what each supports, are listed in [adapters/README.md](../adapters/README.md). This page is for writing one.

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
| `supports` | `zom.Supports` | no | The query features the dataset handles; the defaults when missing. A strict relation that uses one left out does not compile; see [Query support](api.md#query-support-strict-and-fallback). |
| `filterable` | `fn (comptime field: []const u8, comptime op: zom.Op) bool` | no | Narrows `supports` per attribute, for a backend that only filters on some (TigerBeetle filters transfers on `ledger` and `code`, not `amount`). Called at compile time, only for ops `supports` allows; false makes that filter unsupported. Without it, every attribute is filterable. |
| `orderable` | `fn (comptime field: []const u8) bool` | no | Narrows ordering per attribute, the same way: called for a field `supports.order_on` (or being the primary key) allows; false makes `order` by it unsupported. TigerBeetle orders by `timestamp` only, not by its key. |
| `strings` | `zom.StringOwnership` | no | `.dataset` (the default): returned strings point into the dataset. `.caller`: `read`, `readProjected` and `insert` allocate them with the allocator passed in, and every string attribute must be a slice. |
| `loadAssociation` | `fn (*Dataset, comptime a: zom.Association, keys: []const a.Key(), Q, Allocator) ![]const []const S.Tuple` | no | Loads the rows of association `a` (declared on another schema, targeting this one) for each key, instead of zom's `in` query and grouping; required to combine a `zom.customAssociation`. See [Custom associations](associations.md#custom-associations-and-loadassociation). |
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
dataset types, and the atomic `sync`. [zom-csv](../adapters/csv/README.md) and [zom-yaml](../adapters/yaml/README.md) are both built
this way. The contract is listed in `src/file.zig` and checked with
`@hasDecl` when the gateway type is built.

`zig build test-adapters` runs every adapter's tests, `zig build test-pg`
only zom-pg's, `zig build test-tigerbeetle` only zom-tigerbeetle's, and `zig build test` runs them all along with the core.
Every adapter's tests should call `zom.lint.run` once it can store the lint
seed rows.

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
