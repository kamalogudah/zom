# Examples

Each directory here is a small application, a Zig package of its own that
depends on zom by path (`.zom = .{ .path = "../.." }` in its
`build.zig.zon`), the same way your application would depend on it. You
build and run each one from inside its directory with `zig build run`, and
`zig build test` runs it and compares what it prints with the output below.

| Example | Adapters | Needs | Checked by |
|---|---|---|---|
| [csv_users](#csv_users-csv-and-memory-side-by-side) | [zom-csv](../adapters/csv/README.md), `zom.memory` | nothing | `zig build test` at the repo root (ci.yml) |
| [pg_repo](#pg_repo-a-repository-and-transactions-on-postgres) | [zom-pg](../adapters/pg/README.md) | a Postgres server | pg.yml |
| [double_entry](#double_entry-a-ledger-on-tigerbeetle) | [zom-tigerbeetle](../adapters/tigerbeetle/README.md) | a TigerBeetle cluster | tigerbeetle.yml |
| [readme.zig](#readmezig-the-docs-code-blocks) | `zom.memory` | nothing | `zig build test` at the repo root |

You need Zig 0.17.1. The examples are not in zom's `.paths`, so a project
that fetches zom doesn't download them; they only run from a checkout.

## How an example is wired

Every example has the same three parts in its `build.zig`:

1. **One dependency, several modules.** zom is one package. Each adapter
   is a module of that package, so an example asks for the package once
   and imports the modules it uses:

   ```zig
   const zom_dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
   const zom = zom_dep.module("zom");
   const zom_csv = zom_dep.module("zom_csv");
   ```

   zom-pg, zom-sqlite and zom-tigerbeetle need a third-party dependency
   (pg.zig, the SQLite amalgamation, or TigerBeetle's prebuilt C client).
   They only exist when you turn them on, with `.pg = true`,
   `.sqlite = true` or `.tigerbeetle = true`, so an application that
   doesn't use them never fetches those dependencies.

2. **A `run` step.** It builds the executable and runs it, passing on
   anything after `--` (`zig build run -- <arg>`).

3. **A `test` step.** It runs the same executable and fails if stdout is
   not exactly the `expected_output` string at the bottom of `build.zig`.
   This keeps the example in step with the API and with the README. The
   steps for the examples that need a server set `has_side_effects = true`,
   because the database is an input the build cache can't see.

## csv_users: CSV and memory side by side

[src/main.zig](csv_users/src/main.zig) uses one `zom.Container` with two
gateways. Users come from [data/users.csv](csv_users/data/users.csv)
through zom-csv, and posts are held in memory. `combine(.posts, ...)`
attaches each user's posts, using one read from each gateway. Both
relations use the same API; only the gateway they name is different.

```sh
cd examples/csv_users
zig build run
```

```text
Achieng <achieng@example.com>
  - Relations are values
  - Gateways side by side
Baraka <baraka@example.com>
  (no posts)
Wanjiru <wanjiru@example.com>
  - Reading CSV with zom
```

`data/` is found relative to the working directory, so the `run` step sets
its working directory to `examples/csv_users`. That way it works from
whichever directory you start `zig build` in. The root build's
`test-examples` step (part of `zig build test`) runs this example's
`zig build test`, so it is checked on every CI run.

Try it: add a row to `data/users.csv` and run again. If you add a column
that the `User` struct doesn't have, the run fails with
`error.SchemaMismatch` and a message naming the file and the column (see
[zom-csv](../adapters/csv/README.md#loading)).

## pg_repo: a repository and transactions on Postgres

[src/main.zig](pg_repo/src/main.zig) is a container with one zom-pg
gateway, a repository with a custom view (`active`, rom's
`def active = where(deleted_at: nil)`), and a sign-up that writes a user
and their first posts in one transaction. The second sign-up fails part
way through on purpose, and both its writes are rolled back. At startup
the program checks the tables against its schema structs with
`Gateway.verify`.

```sh
# 1. A throwaway Postgres
docker run --rm -d --name zom-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:17
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres

# 2. The tables (zom has no migrations)
cd examples/pg_repo
psql "$DATABASE_URL" -f schema.sql   # or: docker exec -i zom-pg psql -U postgres < schema.sql

# 3. Run it
zig build run                        # or: zig build run -- postgres://...
```

```text
committed: Achieng, with 2 posts
rolled back: DuplicatePrimaryKey (posts_pkey)
  users named Baraka: 0, posts by user 2: 0
active users: 1 of 2
Achieng <achieng@example.com>
  - Relations are values
  - Transactions roll back
```

Each run empties the two tables first, so you can run it as many times as
you like and it prints the same output. The database URL is the first
argument, or `DATABASE_URL` if there is no argument. If neither is set, it
exits with `no database: set DATABASE_URL, ...`. If the tables are missing
or don't match the structs, it prints what differs and reminds you to run
`schema.sql`.

`zig build test` does the same run and checks the output. zom-pg's CI
workflow (`.github/workflows/pg.yml`) runs it against a Postgres 17 service
container, in a database of its own. When you're done:
`docker stop zom-pg`.

## double_entry: a ledger on TigerBeetle

[src/main.zig](double_entry/src/main.zig) does double-entry bookkeeping
through zom relations and changesets only. Nothing in it talks to the
TigerBeetle client directly. It opens a bank and a customer account in one
linked chain, makes a deposit, posts a purchase and its fee as a linked
chain, and has a withdrawal plus fee refused as a whole (`ExceedsCredits`).
Then it reads back the balances and the customer's history with `combine`.

```sh
# 1. A single-replica dev cluster (tigerbeetle 0.17.9, the client's version)
tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development 0_0.tigerbeetle
tigerbeetle start --addresses=3000 --development 0_0.tigerbeetle &

# 2. Run it
cd examples/double_entry
TB_ADDRESSES=3000 zig build run      # or: zig build run -- 3000
```

```text
opened: bank, customer (ledger 700)
deposit: 1000
linked: purchase 250 + fee 5, both posted
refused: withdrawal 740 + fee 10: event 1 failed with ExceedsCredits, nothing posted
balances:
  bank      debits 1000  credits  255  net  -745
  customer  debits  255  credits 1000  net  +745
customer history:
  +1000  balance 1000
  -250   balance 750
  -5     balance 745
```

TigerBeetle keeps every record and never reuses an id, so each run opens
two new accounts with random ids. That is why it prints the same output
every time, even on the same cluster. If you start the client right after
`tigerbeetle start`, you may see a few `on_connect: error.ConnectionRefused`
warnings on stderr while the replica comes up. The client retries, and they
don't affect the output.

The first build fetches TigerBeetle's prebuilt C client (a lazy dependency
of zom's). The client ships for x86_64 and aarch64 Linux and macOS, and
x86_64 Windows. zom-tigerbeetle's CI workflow
(`.github/workflows/tigerbeetle.yml`) runs `zig build test` here against a
dev cluster.

## readme.zig: the docs' code blocks

[readme.zig](readme.zig) isn't a program. It holds the code blocks of the
top-level [README](../README.md) and of [docs/](../docs) as tests, so the
docs can't drift from the API. The
[Postgres walkthrough](../docs/postgres-walkthrough.md) is the exception,
because its code lives in pg_repo. From the repo root, `zig build test`
runs it along with everything else.

## Running all of them

From the repo root:

```sh
zig build test -Dpg=false                     # core, csv/yaml/sql, csv_users, readme.zig
(cd examples/pg_repo && zig build test)       # needs DATABASE_URL and schema.sql applied
(cd examples/double_entry && TB_ADDRESSES=3000 zig build test)
```

## Adding an example

1. Create `examples/<name>/` with a `build.zig.zon` that depends on
   `.zom = .{ .path = "../.." }`, and a `build.zig` with `run` and `test`
   steps (copy csv_users').
2. If it needs no server, add its name to `example_dirs` in the root
   `build.zig`, so `zig build test` runs it. If it does, add a step to that
   adapter's workflow, as pg.yml and tigerbeetle.yml do.
