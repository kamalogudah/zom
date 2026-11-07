# zom-sqlite

A [zom](../../README.md) gateway for SQLite. Statements come from
[zom-sql](../sql) (`Dialect.sqlite`). zom-sqlite runs them on one
`sqlite3` connection, binds their parameters and decodes the rows.

It passes the whole `zom.lint` suite. It has every capability, including
`transaction`, and every query feature, including joins and `combine`'s
per-parent paging (`ROW_NUMBER()`). It also runs the same scenario, join
and combine tests as zom-pg. All of them use in-memory databases, so
`zig build test` covers zom-sqlite with no server and no environment
variable.

## Setup

zom-sqlite is the `zom_sqlite` module of the zom package. It compiles the
[SQLite amalgamation](https://sqlite.org/amalgamation.html) (3.54.1, pinned
in zom's `build.zig.zon`) into the module and translates `sqlite3.h` with
`translate-c`. It needs no system library and no third-party Zig wrapper,
only libc. The amalgamation is a lazy dependency, so zom only fetches it
when asked with `.sqlite = true`. In your `build.zig`:

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize, .sqlite = true });
exe.root_module.addImport("zom", dep.module("zom"));
exe.root_module.addImport("zom_sqlite", dep.module("zom_sqlite"));
```

Open a gateway on a file, or on `":memory:"` (the default) for a private
database that is gone at `deinit`:

```zig
var gateway = try zom_sqlite.Gateway.init(allocator, .{ .path = "app.db", .journal_mode = .wal });
defer gateway.deinit();

const users = try zom.Relation(UserSchema, zom_sqlite.Gateway).init(&gateway);
```

| `Config` field | Default | |
|---|---|---|
| `path` | `":memory:"` | A file path, `":memory:"`, or a `file:` URI. |
| `mode` | `.read_write_create` | `.read_write` needs the file to exist; `.read_only` makes writes `error.ReadOnly`. |
| `busy_timeout_ms` | `5000` | How long a statement waits for another connection's lock before `error.Busy`. |
| `foreign_keys` | `true` | `PRAGMA foreign_keys`. SQLite's own default is off. |
| `journal_mode` | `null` | `PRAGMA journal_mode` (`.wal`, `.delete`, ...), or null to keep the database's. |
| `begin` | `.deferred` | How the outermost `transaction` begins: `BEGIN`, or `.immediate` for `BEGIN IMMEDIATE`. |
| `statement_cache_size` | `128` | Prepared statements the connection keeps (see [Prepared statements](#prepared-statements)). `0` prepares every statement on every call. |

`init` returns `error.ConnectionFailed` when the file can't be opened.

Each schema maps to the table named by its dataset name, and each field to
the column of the same name. zom has no migrations, so create the tables
yourself. `gateway.exec(sql)` runs SQL with no parameters and no rows, and
it accepts several statements separated by `;`.

### Threads

A gateway is one connection, for one thread at a time. To share a
database between threads, open one gateway per thread on the same file.
With `.journal_mode = .wal`, readers don't wait for a writer.
`gateway.handle()` returns the raw `*sqlite3` for anything zom-sqlite
doesn't wrap (backups, custom functions). The translated header is
`zom_sqlite.c`.

## Types

SQLite stores a type with each value, not with each column. zom-sqlite
reads each value by its own type (its storage class) and refuses a value
of the wrong class rather than converting it.

| Zig field | Stored as | Read from |
|---|---|---|
| integers (`u8` … `i64`, `u64` up to 2^63-1) | `INTEGER` | `INTEGER`; a value outside the field's range is `error.ValueOutOfRange` |
| `f32`, `f64` | `REAL` | `REAL` or `INTEGER` |
| `bool` | `INTEGER` 0 / 1 | `INTEGER` 0 or 1 |
| enums | `TEXT`, the tag name | `TEXT` |
| `[]const u8`, `[:0]const u8` | `TEXT` | `TEXT` or `BLOB` |
| `?T` | `NULL` for null | `NULL`, or what `T` reads |

A value of any other class is `error.ColumnTypeMismatch`, for example text
in an integer field. A `NULL` in a non-optional field is
`error.UnexpectedNull`. SQLite has no unsigned 64-bit or 128-bit integers,
so binding a `u64` or `u128` past 2^63-1 is `error.ValueOutOfRange`.

Declare tables `STRICT` (as the lint tests do) to make SQLite check each
value's type on write, as Postgres does. Without `STRICT`, the columns
take anything, and a bad value is only found when it is read.

String ownership is `.caller`. Every string a read or `insert` returns is
copied into the allocator you passed, so free reads with
`relation.free(allocator, rows)` and single tuples with `freeOne`, or read
into an arena. Create with `commitAlloc`.

## Transactions

```zig
try gateway.transaction(&ctx, struct {
    fn f(c: *Ctx, tx: *zom_sqlite.Gateway) !void {
        const accounts = try zom.Relation(Accounts, zom_sqlite.Gateway).init(tx);
        // ...
    }
}.f);
```

`transaction` begins (`BEGIN`, or `BEGIN IMMEDIATE` with
`.begin = .immediate`), calls `f`, and commits. If `f` or the commit
fails, it rolls back and returns the error unchanged. Some differences
from zom-pg:

- `tx` is the same gateway. There is only one connection, so everything
  run on it inside `f` is part of the transaction, whether it goes through
  `tx` or not. Another gateway on the same file sees nothing until the
  commit.
- A nested `transaction` is a `SAVEPOINT` and rolls back on its own. So is
  a `transaction` inside a `BEGIN` you sent yourself with `exec`; it leaves
  your transaction open.
- A failed statement undoes only itself and doesn't abort the
  transaction, so `f` can catch an error and carry on.
- `createMany` runs its multi-row `INSERT`s in a savepoint (or a
  transaction of their own), all or nothing.
- With `.begin = .deferred`, the write lock is taken by the first write,
  which can fail with `error.Busy` if another connection holds it. Use
  `.immediate` for transactions that write, so that they wait up front.

`zom.Container.transaction(.db, ctx, f)` works the same way.

## Errors

| Error | When |
|---|---|
| `error.DuplicatePrimaryKey` | A `PRIMARY KEY` or `UNIQUE` constraint failed. |
| `error.NotFound` | The schema's table does not exist. |
| `error.ReadOnly` | The database was opened `.read_only`, or its file can't be written. |
| `error.Busy` | Another connection held a lock past `busy_timeout_ms`. |
| `error.ValueOutOfRange` | A parameter SQLite can't hold, or a value that doesn't fit its field. |
| `error.ConnectionFailed` | The file can't be opened, or isn't a database. |
| `error.Database` | Anything else, including `CHECK`, `NOT NULL` and foreign key failures. |

`zom_sqlite.Gateway.lastError()` returns the last SQLite error on the
calling thread: `code`, the extended result code (for example
`SQLITE_CONSTRAINT_UNIQUE`; `primary()` gives the primary code), and
`message`, for example `"UNIQUE constraint failed: users.email"`. Errors
are also logged at debug level under the `.zom_sqlite` scope.

## Prepared statements

The connection keeps the statements it has run, keyed by their SQL text.
A statement that comes back, such as a `get` by key, each level of a
`combine` or `insertMany` batches, is compiled once and after that only
reset, bound and stepped. SQLite re-prepares a kept statement by itself
after a schema change. When `statement_cache_size` statements are kept,
keeping another finalizes one of the others (any of them, not the least
recently used).

## How it compiles SQLite

`build.zig` compiles the amalgamation with:

- `SQLITE_CASE_SENSITIVE_LIKE`, so `like` matches case exactly as it does
  in memory. `ilike` is rendered as `LOWER(x) LIKE LOWER(y)`, which folds
  ASCII only.
- `SQLITE_DQS=0`, so a double-quoted name is always an identifier, as
  zom-sql quotes them.
- `SQLITE_DEFAULT_FOREIGN_KEYS=1`, `SQLITE_OMIT_LOAD_EXTENSION`,
  `SQLITE_OMIT_DEPRECATED` and `SQLITE_OMIT_SHARED_CACHE`.

To move the pin:

```sh
# from the repo root; then put `.lazy = true` back on the sqlite entry
zig fetch --save=sqlite https://www.sqlite.org/<year>/sqlite-amalgamation-<version>.zip
```

## Not yet

- No `verify` or `infer`. Unlike zom-pg, it doesn't check a table against
  its struct at startup or generate structs from a database. A driver can
  fill `zom_sql.infer.Catalog` from `PRAGMA table_info`, the way zom-pg
  does from `information_schema`.

## Testing

```sh
zig build test-sqlite   # lint, scenario, join, combine, transactions, errors, cache
```
