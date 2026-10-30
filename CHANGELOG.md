# Changelog

All notable changes to zom are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). While zom is on `0.x`, a minor
bump (`0.2` to `0.3`) may break the public API; a patch bump never does.

## [Unreleased]

### Added

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

### Changed (breaking)

- A gateway must declare `adapter_name`, `Config`, `init(allocator, Config)`
  and `deinit` as well as `Dataset` and `dataset`. ([#12])
- `zom.memory.Gateway.init` takes a `Config` (an empty struct for now):
  write `zom.memory.Gateway.init(allocator, .{})`. ([#12])
- A dataset's `insert`, `update` and `delete` are optional. Without one,
  `create(...).commit()`, `update().commit()` or `delete()` is a compile error
  naming the adapter, instead of a missing-declaration error from
  `zom.Relation`. ([#12])

## [0.2.0] - 2026-10-30

Phase 0 of [plan.md](plan.md): the core is tidied and its public API is
frozen. Adapters written from Phase 1 on build against this release. The
API is listed in the README under [API (v0.2)](README.md#api-v02).

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

[Unreleased]: https://github.com/kamalogudah/zom/compare/v0.2.0...HEAD
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
