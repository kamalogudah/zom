# How zom differs from rom

rom is built on Ruby's runtime: classes register themselves, adapters
subclass base classes, and anything missing shows up as an exception when the
code runs. Zig has none of that, so zom does the same jobs at compile time.
Each row below says whether that part exists today or is planned (see
[plan.md](../plan.md)).

| | rom (Ruby) | zom (Zig) |
|---|---|---|
| **Adapter registry** | `ROM.register_adapter(:csv, ROM::CSV)` puts the adapter in a global runtime table, and `ROM.container(:csv, path)` finds it there by symbol. | Zig has no runtime registry, and zom doesn't need one. An adapter is a Zig module that exports a `Gateway` type, and you pass that type in directly: `zom.Relation(Schema, zom_csv.Gateway)`. The contract is checked when the code compiles, not when it runs. `zom.Adapter` checks it, for `zom.memory` or any gateway you write. zom ships its adapters as modules of the zom package (`dep.module("zom_csv")`), not as separate packages; see [Writing an adapter](adapters.md#writing-an-adapter). |
| **Adapter shape** | Adapters subclass `ROM::Gateway`, `ROM::Relation` and `ROM::Memory::Dataset`, then override methods. | No inheritance. A gateway is any type with the right declarations (see [the adapter contract](adapters.md#the-adapter-contract)). File adapters *wrap* the memory engine, `zom.memory.Store(S)`, instead of subclassing it. |
| **Optional features** | Whether an adapter supports a command is found out at runtime, when the command is built or run. | An adapter simply leaves out `insert`, `update` or `delete`, and `relation.create(...).commit()` fails to compile with a message naming the adapter. `zom.Adapter(G).capabilities(S)` says what it supports. |
| **Checking an adapter** | `ROM::Lint` specs, run by each adapter gem. | `zom.lint.run(Gateway, Factory)`, a test suite each adapter runs in its own `zig build test`. *Today: read, filter, null, ordering, limit/offset, `one`, projection, insert, `insertMany`, update and delete checks.* |
| **Container** | `ROM.container` builds a runtime registry: `container.relations[:users]`. | Relations are types, so a container is a comptime struct with one field per relation: `app.relations.users`. A missing relation is a compile error, not a runtime lookup failure. *Today: `zom.Container`.* |
| **Schema inference** | rom-sql can read a table's columns from the database at boot. | A Zig struct has to exist when the code compiles, before any database is reachable, so you write the schema struct yourself, or generate it ahead of time from a live database with zom-pg's `zig build infer` step, and check it at startup with `Gateway.verify`. |
| **Structs** | `ROM::Struct` builds result classes at runtime from the schema. | You declare the entity struct (or use the tuple), and `mapTo` copies fields by name. `select(.{ .id, .name })` reads into a narrower struct built at compile time with `@Struct`, so reading a field that wasn't selected is a compile error. |
| **Type errors** | Found at runtime, if the database or a type check catches them. | Found at compile time: wrong field names, wrong value types, `null` on a non-optional field, an enum value that doesn't exist, an integer literal that doesn't fit. |
| **Errors** | Exceptions. | Error sets: `error.DuplicatePrimaryKey`, `error.ValueOutOfRange`, `error.MoreThanOneTuple`, returned with `try`. |
| **Memory** | Garbage collected. | Every call that returns a slice takes an allocator, and the caller frees the slice (see [Memory rules](memory.md#memory-rules)). |
| **Transformations** | Changeset `map { ... }` takes a block, which can capture variables. | `map` takes a comptime function, `fn (Tuple) Tuple`. Zig has no closures, so anything it needs has to be in the tuple. |
| **Limits** | Queries grow as needed. | Filters and changes are capped at 16 each, with asserts, so building a query never allocates. |
