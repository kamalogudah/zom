# Roadmap

[plan.md](../plan.md) lays out the path from this toolkit to a core with
separate adapters, the way rom-core pairs with rom-sql, rom-csv and
rom-yaml:

0. Tidy the core and freeze the API as v0.2. *Done in 0.2.0.*
1. Adapter contract, `zom.lint` conformance suite, and `zom.Container`.
2. `zom-csv` and `zom-yaml`, built on the memory engine.
3. `zom-sql` compiler and the `zom-pg` driver on `karlseguin/pg.zig`,
   with projections and a richer query AST. *zom-sql is in `adapters/sql`
   and zom-pg in `adapters/pg`; transactions and CI against a Postgres
   container are next.*
4. Associations in the schema, and `combine` with one `IN (...)` query
   instead of the O(n·m) `combineMany`, now deprecated.
5. Repositories, transactions and plugins (timestamps, pagination).
   *Done: repositories, `container.transaction`, the `timestamps` and
   instrumentation plugins, pagination, and the
   [Postgres example](postgres-walkthrough.md#a-repository-and-a-transaction-on-postgres).*
6. `zom-tigerbeetle` on the native Zig client: immutable accounts and
   transfers, batched writes. *Done: `adapters/tigerbeetle`.*
7. `zom-sqlite` on the SQLite amalgamation, compiled in, on zom-sql's
   `.sqlite` dialect. *Done in 0.16.1: `adapters/sqlite`.*
