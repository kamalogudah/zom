# Adapters

An adapter is a module that exports a `Gateway` type. You pass that type to
`zom.Relation(Schema, Gateway)` or to a `zom.Container`'s `.gateways`. A
relation never runs anything itself. It builds a `Query(T)` value, and the
gateway's dataset carries it out. So the same relation code works in
memory, against files, or against a database. Only the gateway type
changes.

All adapters ship as modules of the one zom package:

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
const zom = dep.module("zom");         // includes zom.memory
const zom_csv = dep.module("zom_csv"); // also zom_yaml, zom_sql
// .pg = true          -> dep.module("zom_pg")          (fetches pg.zig)
// .tigerbeetle = true -> dep.module("zom_tigerbeetle") (fetches TigerBeetle's C client)
```

| Adapter | Module | Backing store | Writes | Transactions | Docs |
|---|---|---|---|---|---|
| memory | `zom.memory` (in core) | in-process `Store(S)` | yes | yes (snapshots) | [docs/adapters.md](../docs/adapters.md#memory-adapter-semantics) |
| csv | `zom_csv` | one `.csv` file per dataset | `WritableGateway` + `sync()` | no | [csv/README.md](csv/README.md) |
| yaml | `zom_yaml` | one YAML file, or one per dataset | `WritableGateway` + `sync()` | no | [yaml/README.md](yaml/README.md) |
| sql | `zom_sql` | none: a SQL compiler, not a gateway | n/a | n/a | [sql/README.md](sql/README.md) |
| pg | `zom_pg` | PostgreSQL, via pg.zig | yes | yes | [pg/README.md](pg/README.md) |
| tigerbeetle | `zom_tigerbeetle` | a TigerBeetle cluster | inserts only (records are immutable) | `linked()` chains | [tigerbeetle/README.md](tigerbeetle/README.md) |

What a gateway leaves out is a **compile error**, not a runtime one. For
example, `relation.create(...).commit()` on a read-only CSV gateway, or
`update()` on TigerBeetle transfers, doesn't compile, and the message names
the adapter. `zom.Adapter(G).capabilities(S)` reports what a gateway
supports.

## Choosing one

- **Tests and prototypes:** `zom.memory`. It needs no setup and passes
  `zom.lint`, and `transaction` restores every store if the function fails,
  so you can test transactional code without a database.
- **Fixtures, seed data, config-like tables:** zom-csv or zom-yaml. Each
  loads its files into a memory store on first use, so queries behave
  exactly as they do in memory. Writes stay in memory until you call
  `sync()`, which rewrites the file atomically.
- **An application database:** zom-pg. It has every capability, including
  joins and transactions, and can generate your schema structs from the
  live database (`zig build infer`).
- **Money and ledgers:** zom-tigerbeetle. It has fixed `Account`,
  `Transfer` and `AccountBalance` schemas, typed result-code errors, and
  linked chains that commit all or nothing.
- **Another SQL database:** zom-sql compiles relations to SQL for a
  `Dialect` (Postgres and SQLite presets). You pair it with a driver to
  build a gateway, the way zom-pg does.

You can mix gateways in one container. See
[examples/csv_users](../examples/csv_users), where users come from CSV and
posts from memory.

## Testing them

```sh
zig build test-adapters      # every adapter's tests
zig build test-pg            # zom-pg only (database tests need ZOM_PG_URL)
zig build test-tigerbeetle   # zom-tigerbeetle only (cluster tests need ZOM_TB_ADDRESSES)
```

The tests of every adapter that can store rows run `zom.lint.run`, the
shared conformance suite. To write your own adapter, see
[Writing an adapter](../docs/adapters.md#writing-an-adapter) and
[the adapter contract](../docs/adapters.md#the-adapter-contract).
