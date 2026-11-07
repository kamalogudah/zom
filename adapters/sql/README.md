# zom-sql

The driver-free half of rom's `rom-sql`. zom-sql compiles a relation's
query into a parameterized `SELECT`, and inserts, updates and deletes into
`INSERT`, `UPDATE` and `DELETE`, for a `Dialect`. It is **not a gateway**:
it never opens a connection. A gateway pairs it with a driver.
[zom-pg](../pg/README.md) is that pairing for Postgres: compile, bind
`params`, decode rows.

Use it directly to:

- build a gateway for another SQL database (SQLite, MySQL, ...);
- log or snapshot-test the SQL that a relation produces;
- run zom's queries through a driver you already have.

## Setup

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zom", dep.module("zom"));
exe.root_module.addImport("zom_sql", dep.module("zom_sql"));
```

It depends only on zom. You need a relation value to compile, and any
gateway type provides one. The memory gateway is enough, and nothing is
read from it:

```zig
const zom_sql = @import("zom_sql");

const compiled = try zom_sql.compileRelation(.postgres, allocator, users.where(.age, .gte, 18).select(.{ .id, .name }));
defer compiled.deinit(allocator);
// compiled.sql:    SELECT "id", "name" FROM "users" WHERE "age" >= $1
// compiled.params: .{ .{ .int = 18 } }
```

The relation's schema name is the table. Its `Output` (the tuple, or the
fields `select` kept) gives the columns.

## Dialects

A `Dialect` is always a comptime argument, so each dialect gets its own
specialised compiler.

| Field | Meaning | `.postgres` | `.sqlite` |
|---|---|---|---|
| `placeholder` | `.dollar_n` (`$1`) or `.question` (`?`) | `$n` | `?` |
| `quote` | wraps every identifier; a quote inside a name is doubled | `"` | `"` |
| `returning` | appends `RETURNING *` to inserts | yes | yes (3.35+) |
| `ilike` | has `ILIKE`; otherwise `LOWER(x) LIKE LOWER(y)` | yes | no |
| `nulls_order` | understands `NULLS LAST`; otherwise `x IS NULL ASC, x ASC` | yes | yes (3.30+) |
| `limit_all` | what follows `LIMIT` when there's only an offset | `null` | `"-1"` |
| `max_params` | most bind parameters in one statement (no default) | 65535 | 32766 |

For another database, write your own. MySQL, for example:

```zig
const mysql: zom_sql.Dialect = .{
    .placeholder = .question,
    .quote = '`',
    .returning = false,
    .ilike = false,
    .nulls_order = false,
    .limit_all = "18446744073709551615", // MySQL has no bare OFFSET
    .max_params = 65535,
};
```

## API

| Declaration | What it is |
|---|---|
| `compileRelation(dialect, allocator, relation) !Compiled` | The usual entry point. |
| `compileSelect(dialect, T, allocator, table, query) !Compiled` | Every field of `T`. |
| `compileProjected(dialect, T, Out, allocator, table, query) !Compiled` | Only `Out`'s fields, e.g. `zom.Project(T, .{ .id })`. |
| `compileInsert(dialect, T, allocator, table, row) !Compiled` | `INSERT INTO "t" ("a", "b") VALUES ($1, $2)`. |
| `compileInsertMany(dialect, T, allocator, table, rows) !Batch` | Multi-row `VALUES`, split into statements of `rowsPerStatement(dialect, T)` rows each so that none passes `max_params`. Each statement numbers from `$1`. Run them in order, in a transaction if they must be all or nothing. |
| `compileUpdate(dialect, T, allocator, table, query, changes) !Compiled` | `UPDATE "t" SET "a" = $1 WHERE ...`. A field set twice takes its last value. |
| `compileDelete(dialect, T, allocator, table, query) !Compiled` | `DELETE FROM "t" WHERE ...`. |
| `Compiled` | `sql: []u8` and `params: []zom.Value`, one per placeholder, in order. Free with `deinit(allocator)`. |
| `Batch` | `statements: []Compiled`, in row order; `deinit(allocator)` frees all. |
| `writeSelect`, `writeInsert`, `writeUpdate`, `writeDelete` | The same statements rendered into any `*std.Io.Writer`. |
| `writeIdent(dialect, writer, name)` | One quoted identifier. |
| `infer` | Zig schema source from a database catalog (see below). |

String params borrow from what you passed in: the query, the tuples, or
the changes. Values go through `zom.query.toValue`, so a null optional
binds `.null` and an enum binds its tag name.

## What gets rendered

Every identifier is quoted, and every node of a query is rendered:

- `AND` / `OR` groups in parentheses, `NOT (...)`, `IN (...)`,
  `LIKE ... ESCAPE '\'`, `BETWEEN`, `IS [NOT] NULL`, several `ORDER BY`
  keys, `LIMIT` and `OFFSET`.
- **Joins** (`users.join(.posts).whereJoined(.posts, .published, .eq, true)`)
  become a correlated semi-join, one `EXISTS` per join, AND-ed:

  ```sql
  SELECT ... FROM "users" WHERE <own filters>
    AND EXISTS (SELECT 1 FROM "posts" WHERE "posts"."user_id" = "users"."id" AND "posts"."published" = $1)
  ```

  Each source row is kept once, with no `DISTINCT` needed. A self-join
  aliases the joined table by the association's name.
- **Per-parent paging** (what `combine` pushes down for `limit`/`offset`
  on the child relation) becomes `ROW_NUMBER() OVER (PARTITION BY <key>
  ORDER BY ...)` in a derived table, so only the rows kept are sent.

The SQL is true, false or unknown exactly where the memory adapter's
`Query.truth` is, so a relation returns the same rows in memory and in the
database:

- `IN ()` isn't valid SQL, so an empty `in` is `1=0` and an empty `not_in`
  is `1=1`. On a nullable column these stay unknown for a null, as in
  memory.
- A nullable sort key says where its nulls go (`ASC NULLS LAST`,
  `DESC NULLS FIRST`), matching memory and Postgres's default.
- `limit` and `offset` are clamped to the largest bigint.

### Safety rails

- **Unfiltered writes are refused.** `compileUpdate` and `compileDelete`
  return `error.UnboundedWrite` for a query with no filters or join, so a
  forgotten `where` can't rewrite or empty a table. Set `query.all = true`
  if you mean it. `order`, `limit` and `offset` don't count as filters, and
  write statements ignore them.
- An update with no changes is `error.EmptyUpdate`.
- `lt` / `lte` / `gt` / `gte` against `null` is
  `error.InvalidNullComparison`. `eq null` and `neq null` are `IS NULL`
  and `IS NOT NULL`.

The remaining differences from memory come from the database itself: an
enum stored as text sorts by name; SQLite's `LIKE` ignores ASCII case
unless `PRAGMA case_sensitive_like = ON`; and Postgres rejects a pattern
ending in a lone `\`.

## Schema inference

A Zig struct must exist at compile time, before any database is reachable,
so zom can't read columns at boot the way rom-sql does. Instead,
`zom_sql.infer` turns a `Catalog` (tables, columns, enums) into a source
file of tuple structs, `zom.Schema` declarations and enums, which you
commit:

```zig
// generated by zom-sql infer from schema "public"; do not edit
const zom = @import("zom");

pub const Users = struct {
    id: i32,
    name: []const u8,
    deleted_at: ?i64 = null,
};
pub const UsersSchema = zom.Schema(Users, "users", .id, .{});
```

`infer` knows nothing about SQL type names. A driver fills the catalog and
maps each column to a `Type`, or to null for a type it can't decode, which
is then left out with a comment. zom-pg does this for Postgres; run it with
`zig build infer` (see
[Generating the schema structs](../pg/README.md#generating-the-schema-structs)).

## Building a gateway on zom-sql

Roughly what zom-pg's dataset does for each call:

1. `read`: `compileRelation`/`compileProjected`, bind `params` in order,
   run, and decode each row by column name into the tuple's fields
   (`zom.codec.decodeField` handles any column that arrives as text).
2. `insert` / `insertMany`: `compileInsert` / `compileInsertMany`. With
   `returning`, read back the stored row.
3. `update` / `delete`: `compileUpdate` / `compileDelete`, and return the
   affected-row count.
4. Declare `supports` to match what the SQL can express (zom-sql renders
   everything, joins included), and run `zom.lint.run` in your tests.

See [the adapter contract](../../docs/adapters.md#the-adapter-contract) for the
declarations a gateway needs.

## Testing

```sh
zig build test-adapters   # zom_sql's snapshot tests: selects, writes, joins, infer
```
