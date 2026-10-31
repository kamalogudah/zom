# Changelog

All notable changes to zom are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). While zom is on `0.x`, a minor
bump (`0.2` to `0.3`) may break the public API; a patch bump never does.

## [Unreleased]

### Added

- `zom_yaml.Gateway` and `zom_yaml.WritableGateway`, with the same structure
  as zom-csv. `Config.path` is one YAML file mapping every dataset name to
  its records (rom-yaml's layout), or a directory of `<name>.yaml` files,
  each a bare sequence. Each dataset is loaded into a `zom.memory.Store(S)`
  on first use. Every record's keys are checked against the schema: a
  missing required key or an unknown one (unless `unknown_keys = .ignore`)
  is `error.SchemaMismatch`, and the message names the file, the line, the
  dataset, the 0-based list index and every bad key, as in
  `data.yaml:4: users[1]: missing key "name"`. Values decode through
  `zom.codec`, and errors read `data.yaml:6: users[1].age: "old" is not an
  integer from 0 to 255`. YAML null on a non-optional field is
  `error.UnexpectedNull`. On an optional field it wins over the field's
  default. `WritableGateway.sync()` writes records with keys in schema order
  and null as `~`. It quotes strings that other YAML readers would type
  (`"123"`, `"yes"`) and anything that can't be written plain. A
  single-file sync re-reads the file and keeps the other datasets as they
  are, in order and with their quoting. Comments are not kept.
  `writeRecords` and `writeDataset` write the same format. ([#27])
- `zom.file`, which zom-csv and zom-yaml now share:
  `Gateway(Format, mode)` and `FileDataset(S, Format, mode)` hold the file
  lookup, size limit and BOM handling, lazy per-dataset loading, the
  read-only and writable dataset types, the dirty flag and the atomic
  `sync`. A format supplies `name`, `extension`, `layout` (`.one_per_file`
  or `.all_in_file`), `Config`, `WriteError`, `load`, `dump` and optionally
  `State(S)`. Missing or mistyped declarations are listed in one compile
  error. `zom.file.Diagnostic` (with `list` for several problems in one
  message) and `zom.file.Unknown` replace the CSV-only versions;
  `zom_csv.Diagnostic` and `zom_csv.UnknownColumns` are now aliases of
  them, so zom-csv's API and messages are unchanged. ([#27])
- `yaml.writeScalar(writer, value, style)`, which writes a key or value
  that the parser reads back as the same bytes. `yaml.Field.quoted` says
  whether a value was quoted. ([#27])
- `zom.codec.Diagnostic.formatProblem`, the message without the
  `row:column (field)` prefix, for adapters that name the place their own
  way. ([#27])

- `zom-yaml` (`adapters/yaml`), starting with `yaml.parseDatasets` and
  `yaml.parseRecords`. They parse a documented subset of YAML: a mapping
  from dataset name to a block sequence of flat records, or one bare
  sequence. Every record field is a key mapped to scalar text, or `null`
  for `~`, `null`, `Null`, `NULL` and an empty value; `zom.codec` decodes
  the text. Scalars may be plain, `'single'` (with `''`) or `"double"`
  (with every YAML escape, including `\xXX`, `\uXXXX` and `\UXXXXXXXX`).
  Comments, blank lines, CRLF, a BOM and a leading `---` are accepted.
  `users: []` and `users:` with no items are empty datasets. Anchors,
  aliases, tags, block scalars, flow collections, nested values, complex
  keys, directives and multiple documents fail with
  `error.UnsupportedYaml`. A tab in indentation fails with
  `error.TabIndentation`, and misaligned lines with `error.BadIndentation`.
  Other errors are `UnterminatedQuote`, `InvalidEscape`, `DuplicateKey` and
  `InvalidSyntax`. A `yaml.Diagnostic` gives the line and column and formats
  as `2:6: unsupported YAML: an anchor (&name)`. Values without escapes
  borrow the input. Everything else lives in an arena that the result owns.
  This is our own parser, not kubkon/zig-yaml (findings in [#26]).
  `zig build test-adapters` now runs it too. ([#26])
- `zom_csv.WritableGateway`, the writable twin of `zom_csv.Gateway`. Its
  datasets add `insert`, `insertMany`, `update` and `delete`, which change
  the in-memory store and mark the dataset dirty. `sync()`, on a dataset or
  on the gateway for every dirty one, writes the header and rows to
  `<name>.csv.tmp`, flushes, fsyncs, closes it and renames it over
  `<name>.csv`. On any error the temp file is deleted, the original is left
  byte-for-byte unchanged and the dataset stays dirty. Columns keep the
  order of the header read at load time, and fields that header lacked
  follow in schema order. A new file uses schema order. The file keeps its
  permissions. A missing file is an empty dataset, created by the first
  sync after a write. Unknown columns are rejected even with
  `unknown_columns = .ignore`, because sync would drop them. `deinit` does
  not sync. New `Config.line_ending` (default `"\n"`). `writeTable` now
  reports a full row buffer as `error.OutOfMemory`, not
  `error.WriteFailed`. ([#25])
- `zom-csv`: `csv.Reader` and `csv.writeRow`, an RFC 4180 CSV reader and
  writer. The reader takes the whole file as `[]const u8` and yields rows
  (`while (try reader.next()) |row|`). It handles a configurable separator,
  `\n` and `\r\n` line endings, an optional final line break, and quoted
  cells holding separators, line breaks and `""` escapes. A blank line is a
  zero-cell row. Cells are sub-slices of the input, except cells with `""`
  escapes, which are unescaped into an arena reset on every `next()`. A row
  of up to 64 cells with no escapes makes no allocation. Errors are
  `error.UnterminatedQuote` and `error.UnexpectedQuote`, with the line and
  column in a `csv.Diagnostic` (`3:7: unterminated quote`). `writeRow`
  quotes a cell only when it holds the separator, `"`, `\r` or `\n` (or is
  the only cell and is empty), and doubles inner quotes. ([#23])
- `zom.codec.encodeField(writer, value, opts)` and `encodeRow(writer, T,
  row, opts, sep)`, the inverse of `decodeField`/`decodeRow`, for CSV sync
  and YAML writing. They write integers as `{d}`, floats as the shortest text
  that parses back to the same bits (decimal when `1e-6 <= abs(x) < 1e21`,
  scientific such as `1e300` otherwise), bools as `true`/`false`, enums as
  tag names, strings unchanged and `null` as `Options.null_text`. When
  `null_text` is `null` they fail with `error.NullNotRepresentable`. Nothing
  is quoted, because quoting is the format writer's job. ([#22])
- `zom.codec`, which decodes text cells (CSV, YAML scalars, SQL text
  results) into tuple field types. `decodeField(F, text, opts)` handles
  integers, floats, bools (`true`/`false`/`1`/`0`/`t`/`f`, any case), enums,
  optionals and `[]const u8`, which borrows `text`. `decodeRow(T, cells,
  opts, diag)` builds a whole tuple, with cells in field order or placed by
  `Options.columns`. A missing cell takes the field's default, else `null`,
  else fails with `error.MissingField`. `Options.null_text` (default `""`)
  means null, and a non-optional field given it fails with
  `error.UnexpectedNull`. Whitespace is never trimmed. On error, a
  `Diagnostic` records row, column, field and text, and formats as
  `14:3 (age): "abc" is not an integer from 0 to 255`. ([#21])
- The `adapters/<name>/` package layout, with `adapters/csv` (`zom-csv`) as
  the first, still a stub gateway. Each adapter has its own `build.zig.zon`
  depending on zom through `.path = "../.."`. `zig build test-adapters` runs
  every adapter's `zig build test`, and `zig build test` runs it too.
  `adapters/` is outside zom's `.paths`, so it doesn't affect zom's package
  hash. README: "Writing an adapter". ([#20])
- `zom.lint.run(G, Factory)`, the adapter conformance suite (like rom's
  `ROM::Lint`). It seeds its own schema, `zom.lint.Users`, through the
  factory's `seed` or the dataset's `insertMany`/`insert`, and checks reads,
  every filter op, `null` semantics, ordering with nulls, `limit`/`offset`
  edge cases, `one`, and that `count` matches the rows read. Failures name
  the check and case; checks needing a missing capability or `zom.Supports`
  feature are skipped with a message. The memory adapter passes it. ([#17])
- `zom.lint` write checks: `insert`, `createMany` (with `insertMany` or the
  `insert` fallback), `update` and `delete`, including
  `error.DuplicatePrimaryKey`, `error.ValueOutOfRange`, failed writes changing
  nothing, and strings being copied on every write. A factory can declare
  `insert_many_on_duplicate: zom.lint.OnDuplicate` to say what a failed
  batch leaves stored. `zom.lint.expectSharedError` checks that an adapter
  uses the shared names from `zom.adapter.Error`. Each check is skipped when
  the capability is missing. ([#18])
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
- `zom.Supports` lists the query features a dataset can evaluate (`or`, `in`,
  `like`, `order_on`, `offset`, `projection`, `join`). A dataset declares
  `pub const supports: zom.Supports`; `Adapter(G).supports(S)` returns it,
  or the defaults when there is none. The memory adapter declares `.all`.
  Relations do not check it yet. ([#13])
- `zom.adapter.Error` names the errors every adapter must use for the same
  condition: `DuplicatePrimaryKey`, `ValueOutOfRange`, `NotFound`,
  `ReadOnly` and `ConnectionFailed`. ([#13])
- `Adapter(G).readOnly(S)` is true when the dataset has no `insert`,
  `insertMany`, `update` or `delete`. ([#14])
- `Relation.createMany(tuples)` returns a `changeset.CreateMany`, whose
  `commit()` returns `!usize`, the rows inserted. It calls the dataset's
  `insertMany` when there is one, else loops over `insert`, stopping at the
  first error with the earlier rows still stored; with neither it is a
  compile error. `Adapter(G).requireAny(S, caps, method)` backs that
  check. ([#15])
- `zom.memory` datasets have `insertMany` (`.batch_insert`), which stores
  all or nothing: a duplicate key, against the table or inside the batch, or
  running out of memory stores no rows. ([#15])
- `zom.memory.Store(S)` is the memory adapter's row engine, usable without
  a gateway so file adapters can wrap it. Besides the dataset methods it has
  `rows()` (every row, for writing a file back), `load(row)` and
  `loadMany(rows)` (insert without the primary-key check, for trusted bulk
  loads) and `clear()` (drops every row and resets the string arena).
  `memory.Gateway.Dataset(S)` is `Store(S)`. ([#16])
- `zom.Container(.{ .gateways = ..., .relations = ... })`, like
  `ROM.container`: declares gateways and the relations over them once, and
  generates `Gateways`, `Relations` and `Config` structs. `app.init(allocator,
  config)` initialises the gateways in declaration order and builds the
  relations, deinitialising the gateways already initialised if anything
  fails; `deinit` runs in reverse. `init` fills the container in place, so it
  must not be moved before `deinit`. An unknown gateway name or an invalid
  gateway is a compile error. ([#19])

### Changed (breaking)

- A gateway must declare `adapter_name`, `Config`, `init(allocator, Config)`
  and `deinit` as well as `Dataset` and `dataset`. ([#12])
- `zom.memory.Gateway.init` takes a `Config` (an empty struct for now):
  write `zom.memory.Gateway.init(allocator, .{})`. ([#12])
- A dataset's `insert`, `update` and `delete` are optional. Without one,
  `create(...).commit()`, `update().commit()` or `delete()` is a compile error
  naming the adapter, instead of a missing-declaration error from
  `zom.Relation`. ([#12])
- `Relation.create` and `Relation.update` check the capability themselves,
  so the error points at the call, not at `commit`. `commit` still checks
  for a changeset built by hand. The message now names the relation and the
  capability: ``zom: adapter 'csv' is read-only for relation 'users': `create`
  needs the `writable` capability (dataset has no `insert`)``. ([#14])
- `zom.memory.MemoryDataset(S)` is renamed `zom.memory.Store(S)`. ([#16])
- A dataset's `count` returns the number of rows `read` would return, so
  `limit` and `offset` now apply (they were ignored). `users.limit(2).count()`
  is at most 2. ([#17])

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
[#13]: https://github.com/kamalogudah/zom/issues/13
[#14]: https://github.com/kamalogudah/zom/issues/14
[#15]: https://github.com/kamalogudah/zom/issues/15
[#16]: https://github.com/kamalogudah/zom/issues/16
[#17]: https://github.com/kamalogudah/zom/issues/17
[#18]: https://github.com/kamalogudah/zom/issues/18
[#19]: https://github.com/kamalogudah/zom/issues/19
[#20]: https://github.com/kamalogudah/zom/issues/20
[#21]: https://github.com/kamalogudah/zom/issues/21
[#22]: https://github.com/kamalogudah/zom/issues/22
[#23]: https://github.com/kamalogudah/zom/issues/23
[#25]: https://github.com/kamalogudah/zom/issues/25
[#26]: https://github.com/kamalogudah/zom/issues/26
[#27]: https://github.com/kamalogudah/zom/issues/27
