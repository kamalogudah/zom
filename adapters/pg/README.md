# zom-pg

A [zom](../../README.md) gateway for PostgreSQL, on
[karlseguin/pg.zig](https://github.com/karlseguin/pg.zig). Statements come
from [zom-sql](../sql) (`Dialect.postgres`); zom-pg runs them on a
connection pool, binds their parameters and decodes the rows.

It passes the whole `zom.lint` suite, has every capability including
`transaction`, and every query feature except joins.

## Setup

zom-pg depends on zom and zom-sql by path, and on pg.zig pinned to the
`zig-0.16.0` branch at commit
[`1f2bf9e`](https://github.com/karlseguin/pg.zig/commit/1f2bf9e5487b0884f907cd5a8cc751a02d5f7f9c)
(pg.zig's `master` targets Zig 0.17). To move the pin:

```sh
cd adapters/pg
zig fetch --save=pg "git+https://github.com/karlseguin/pg.zig#<commit>"
```

In your `build.zig`, import the `zom_pg` module next to `zom`:

```zig
const zom_pg = b.dependency("zom_pg", .{ .target = target, .optimize = optimize }).module("zom_pg");
```

Open a gateway with a URL, or with the fields one by one. pg.zig does its I/O
through `std.Io`, so the config takes one:

```zig
var gateway = try zom_pg.Gateway.init(allocator, .{
    .io = io,
    .url = "postgres://app:secret@localhost:5432/app", // or host, port, user, password, database
    .pool_size = 4,
});
defer gateway.deinit();

const users = try zom.Relation(UserSchema, zom_pg.Gateway).init(&gateway);
```

| `Config` field | Default | |
|---|---|---|
| `io` | required | The `std.Io` pg.zig uses for sockets. |
| `url` | `null` | `postgres://` or `postgresql://`, with `?sslmode=require` / `verify-full`. Overrides the fields below. |
| `host`, `port` | `"127.0.0.1"`, `5432` | |
| `user`, `password`, `database` | `"postgres"`, `null`, `null` | |
| `pool_size` | `4` | Connections, all opened by `init`. |
| `acquire_timeout_ms` | `10_000` | How long a call waits for a free connection. |

`init` returns `error.ConnectionFailed` when the server can't be reached or
rejects the login, and `error.InvalidUrl` for a URL it can't parse.

Each schema maps to the table named by its dataset name, and each field to a
column of the same name. zom has no migrations; create the tables yourself
(`gateway.exec(sql)` runs a statement without parameters, which is handy in
tests).

## Checking the schema at startup

Zig can't read the database at compile time, so a struct that has drifted
from its table would otherwise only fail on the first query that touches
the bad column. `gateway.verify(S, diagnostics)` checks it up front:

```zig
var diag: zom_pg.Diagnostics = .init(allocator);
defer diag.deinit();
gateway.verify(UserSchema, &diag) catch |err| switch (err) {
    error.SchemaMismatch => {
        std.log.err("the database doesn't match the schema:\n{f}", .{diag});
        return err;
    },
    else => return err,
};
```

It reads `information_schema` for the table `S.name` resolves to on the
`search_path` (the one the gateway's statements use, `public` by default)
and reports every mismatch at once, one per line:

```
users.age: Zig u8 vs pg text
users.email: Zig []const u8 vs no column
users.name: Zig []const u8 vs pg nullable column (make the field optional or the column NOT NULL)
users: primary key is (email), expected (id)
```

- Every field needs a column whose type holds it: one from the table in
  [Types](#types), and for integers one that holds every value of the
  field (`u8` and `i16` take `smallint` and up, `u16` and `i32` `integer`
  and up, wider ones `bigint`). `zom_pg.pgTypesFor(T)` lists them.
- A non-optional field on a nullable column is a mismatch (reading a NULL
  would fail), and so is a `?T` field on a `NOT NULL` column (writing null
  would).
- The primary key must be `S.primary_key` alone.
- A missing table is one mismatch (`users: no such table`). Columns the
  struct doesn't have are allowed.

With `null` for `diagnostics`, the mismatches are logged at error level
(scope `.zom_pg`) instead. One `Diagnostics` can collect several `verify`
calls, so an application can check all its schemas and report them
together. `verify` also works on the `tx` gateway inside `transaction`.

## Strings belong to the caller

pg.zig's row data is only valid until the next row or the end of the result,
so zom-pg copies every string it returns. **Strings in the tuples from
`read` and `readProjected` are owned by the allocator passed to the read,
and those in the tuple `insert` returns by the allocator passed to it.** The
dataset declares `strings = .caller`, which tells zom so, and the relation
frees them for you:

```zig
const adults = try users.where(.age, .gte, 18).toSlice(allocator);
defer users.free(allocator, adults);

if (try users.byPk(1).one(allocator)) |u| {
    defer users.freeOne(allocator, u);
}

// `commit()` is a compile error here: the stored tuple needs an allocator.
const stored = try users.create(.{ .id = 7, .name = "gus" }).commitAlloc(allocator);
defer users.freeOne(allocator, stored);
```

This differs from the memory, CSV and YAML adapters, whose strings belong to
the dataset. `free`, `freeOne` and `commitAlloc` work on those too, so code
written this way runs unchanged on either. An arena per request is the
simplest alternative: read into it and free it once.

## Types

| Zig attribute | Column | Notes |
|---|---|---|
| `i8` .. `i64`, `u8` .. `u64` | `smallint`, `integer`, `bigint` | Read by the column's type, then range-checked into the field (`error.ValueOutOfRange`). A `u32` needs `bigint`. Values past bigint's range (a `u64` above 2^63-1) can't be stored or compared. |
| `f32`, `f64` | `real`, `double precision`, `numeric` | |
| `bool` | `boolean` | |
| `[]const u8` (or `[:0]const u8`) | `text`, `varchar`, `char(n)` | Copied; see above. |
| an enum | `text`, or a Postgres `ENUM` | Stored as the tag name, read with `zom.codec`. Ordering a text column sorts by name, not declaration order. |
| `?T` | any of the above, nullable | |

Parameters are bound from `zom.Value`: `int` as bigint, `uint` as bigint
after a range check, `float`, `string` as text, `boolean`, and `null`.
Postgres infers each parameter's type from the SQL, and pg.zig converts to
it, refusing a value that does not fit (`error.ValueOutOfRange`).

## Behaviour

- `count` runs `SELECT COUNT(*)` over the compiled `SELECT`, so `limit` and
  `offset` apply, as the contract says.
- `insertMany` runs zom-sql's multi-row `INSERT`s in one transaction (a
  SAVEPOINT inside `transaction`): all or nothing.
- `update` checks each value against the attribute's Zig type before
  sending it, so setting a `u8` to 300 is `error.ValueOutOfRange` even
  though a `smallint` column would take it.
- `update` and `delete` on a relation with no filters touch every row, as on
  the memory adapter (zom-pg sets `query.all`, lifting zom-sql's
  unfiltered-write check).
- `lt` / `lte` / `gt` / `gte` against `null` match nothing at the top level
  of a query. Inside a `whereAny` / `whereNot` group they are still
  zom-sql's `error.InvalidNullComparison`.

## Transactions

`gateway.transaction(ctx, f)` takes a connection from the pool, runs
`BEGIN`, calls `f(ctx, tx)`, and runs `COMMIT`. If `f` (or the `COMMIT`)
fails, it runs `ROLLBACK` and returns that error unchanged. Zig has no
closures, so whatever `f` needs comes in through `ctx`:

```zig
const Transfer = struct { from: u32, to: u32, amount: i64 };

try gateway.transaction(Transfer{ .from = 1, .to = 2, .amount = 50 }, struct {
    fn f(t: Transfer, tx: *zom_pg.Gateway) !void {
        const accounts = try zom.Relation(AccountSchema, zom_pg.Gateway).init(tx);
        _ = try accounts.byPk(t.from).update().set(.balance, ...).commit();
        _ = try accounts.byPk(t.to).update().set(.balance, ...).commit();
    }
}.f);
```

- `tx` is a `*zom_pg.Gateway` pinned to the one connection: every relation
  built on it runs inside the transaction, so relation code is the same as
  outside one. It lives until `transaction` returns, so don't `deinit` it
  or keep relations over it, and use it from one thread. Calls on the outer
  gateway inside `f` are not part of the transaction (they take a second
  connection, so with `pool_size = 1` they wait and then fail).
- `transaction` returns what `f` returns, with `zom_pg.Gateway.Error`
  added to its error set. `f` may also return a plain value.
- **Nested transactions are SAVEPOINTs.** `tx.transaction(ctx, g)` rolls
  back only `g`'s work when `g` fails, and the outer transaction goes on.
- Postgres aborts the whole transaction on any failed statement. If `f`
  catches an error and carries on, every later call fails with
  `error.Database` (SQLSTATE `25P02`), and so does the `COMMIT`, which
  rolls back. To recover from an expected error, such as a duplicate key,
  run that statement in a nested `transaction` and catch the error there.

## Errors

| Error | When |
|---|---|
| `error.DuplicatePrimaryKey` | Any unique violation (SQLSTATE `23505`), on the primary key or on another `UNIQUE` constraint. Telling them apart would need the constraint's name, which can be anything, or a catalog query, which an aborted transaction refuses. `lastError().constraint` says which one it was. |
| `error.ValueOutOfRange` | A value that does not fit the column or the attribute (`22003`, or a check before binding or after decoding). |
| `error.NotFound` | The schema's table does not exist (`42P01`). |
| `error.ReadOnly` | A read-only transaction or replica (`25006`). |
| `error.ConnectionFailed` | The pool can't connect or hand out a connection in time, a socket error, or SQLSTATE class `08`. |
| `error.Database` | Any other Postgres or pg.zig error. |
| `error.MissingColumn`, `error.ColumnTypeMismatch`, `error.UnexpectedNull` | The table doesn't match the schema. Each is logged with the column at debug level. `verify` finds these up front. |
| `error.SchemaMismatch` | From `verify` only: the table doesn't match the schema; the `Diagnostics` say how. |

All of them except the last row are in `zom_pg.Gateway.Error`.

`zom_pg.Gateway.lastError()` returns the last Postgres error on the
calling thread as a `zom_pg.ServerError`: `code` (the SQLSTATE),
`severity`, `message`, and, when the server sent them, `detail`, `hint`,
`table`, `column` and `constraint`. It works like `errno`: it is kept per
thread (so concurrent calls through one pool don't overwrite each other's),
a call that succeeds leaves it as it was, and its strings are valid until
the next Postgres error on that thread. Every Postgres error is also logged
at debug level under the `.zom_pg` scope.

```zig
users.create(u).commitAlloc(allocator) catch |err| switch (err) {
    error.DuplicatePrimaryKey => {
        const e = zom_pg.Gateway.lastError().?;
        std.log.warn("{s} is taken ({s})", .{ u.name, e.constraint orelse "?" });
    },
    else => return err,
};
```

## Testing

The tests include the full lint suite, which needs a database. It is skipped
unless `ZOM_PG_URL` is set:

```sh
createdb zom_test
ZOM_PG_URL=postgres://postgres@127.0.0.1:5432/zom_test zig build test
```

Every check drops and recreates a `lint_users` table, the transaction
and error tests a `tx_items` table, and the `verify` tests a `vf_users`
table and a `vf_role` type, so use a database you can spare those
tables in. Without `ZOM_PG_URL`, `zig build test` (here, or
`zig build test-adapters` at the root) only checks that zom-pg compiles and
satisfies the adapter contract.
