# zom-yaml

A [zom](../../README.md) gateway over YAML files. It is zom's version of
rom's `rom-yaml`. Datasets live either all together in one file or one per
file. Each is loaded on first use into a `zom.memory.Store(S)`, so queries
behave exactly as they do in memory. Joins are not supported.

It works like [zom-csv](../csv/README.md). Both are a `Format` given to
`zom.file.Gateway`, so they share the file lookup, the read-only and
writable types, and the atomic `sync`.

| Type | Datasets have |
|---|---|
| `zom_yaml.Gateway` | `read`, `count`. Writes are compile errors naming the `yaml` adapter. |
| `zom_yaml.WritableGateway` | also `insert`, `insertMany`, `update`, `delete`, `sync` |

Both pass `zom.lint`.

## Setup

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zom", dep.module("zom"));
exe.root_module.addImport("zom_yaml", dep.module("zom_yaml"));
```

```zig
const zom = @import("zom");
const zom_yaml = @import("zom_yaml");

const User = struct { id: u32, name: []const u8, email: ?[]const u8 = null };
const UserSchema = zom.Schema(User, "users", .id, .{});

var gw = zom_yaml.Gateway.init(allocator, .{ .io = io, .path = "seed.yaml" });
defer gw.deinit();
const users = try zom.Relation(UserSchema, zom_yaml.Gateway).init(&gw);
const all = try users.order(.id, .asc).toSlice(allocator);
defer allocator.free(all);
```

| `Config` field | Default | |
|---|---|---|
| `io` | required | The `std.Io` that does the file I/O. |
| `path` | required | One YAML file holding every dataset, or a directory of `<name>.yaml` files. Borrowed. |
| `dir` | `.cwd()` | What a relative `path` is resolved against. Must stay open as long as the gateway. |
| `unknown_keys` | `.reject` | `.ignore` skips keys the schema doesn't have (read-only gateway only). |
| `max_file_bytes` | 64 MiB | A larger file is `error.FileTooBig`. |

## File layouts

**One file, every dataset** (`path` is a file). Each dataset name maps to a
sequence of records:

```yaml
users:
  - id: 1
    name: Achieng
    email: "achieng@example.com"
  - id: 2
    name: 'Otieno'
    email: ~
posts: []
```

A dataset that isn't in the file is `error.NotFound` on `Gateway`, and an
empty dataset on `WritableGateway`.

**One file per dataset** (`path` is a directory). `users.yaml` is a bare
sequence:

```yaml
- id: 1
  name: Achieng
- id: 2
  name: Otieno
```

A missing file is `error.NotFound` on `Gateway`. On `WritableGateway` it
is an empty dataset, and the first `sync` after a write creates the file.

## The YAML subset

zom-yaml reads datasets of **flat records**, with no dependency beyond the
standard library. This is what it accepts:

- A record is a block mapping from keys to scalars. It starts on the `-`
  line or on the lines after a bare `-`.
- A dataset's sequence may be indented under its name or written at the
  same column. `users:`, `users: ~` and `users: []` are all empty.
- Scalars can be plain, `'single-quoted'` (with `''` for a quote) or
  `"double-quoted"` with every YAML escape (`\n`, `\t`, `\uXXXX`, ...).
  Quoted keys are allowed too.
- A plain `~`, `null`, `Null`, `NULL` or an empty value is null. A quoted
  `"~"` or `""` is a string.
- `#` comments (a `#` must follow a space to start one, so `a#b` is data),
  blank lines, `\r\n`, a UTF-8 byte order mark, and a leading `---`.
- Indentation must be spaces. A tab in indentation is
  `error.TabIndentation`.

Anything else that is valid YAML is `error.UnsupportedYaml`, with a message
saying what was found. That covers anchors and aliases, tags, block scalars
(`|`, `>`), flow collections (`[a, b]`, `{a: 1}`), nested mappings or
sequences, `?` keys, directives, multiple documents, and multi-line
scalars.

## Loading

1. The file is parsed. A parse error gives the line and column, for
   example `users.yaml:3:5: unsupported YAML: an anchor (&name)`.
2. Each record's keys are checked against the schema. A missing key for a
   field that is neither optional nor defaulted, or an unknown key (unless
   `.ignore`), is `error.SchemaMismatch`. The message names the record and
   every bad key: `users.yaml:7: users[1]: missing key "name"; unknown key
   "email"`. `WritableGateway` rejects unknown keys even with `.ignore`,
   because `sync` would drop them.
3. Values are decoded with `zom.codec`, so integers, floats, bools, enums,
   strings and optionals follow the same rules as CSV and SQL text (see
   [zom-csv](../csv/README.md#loading)). YAML null is null for an optional
   field, even one with a default, and `error.UnexpectedNull` for any other
   field. A decode error gives the key's line:
   `users.yaml:9: users[2].age: "old" is not an integer from 0 to 255`.
4. Duplicate primary keys are not checked on load, because the file is the
   source of truth.

The message is in `gw.diagnostic.message()` after any failed load or sync.

## Writing back

```zig
var gw = zom_yaml.WritableGateway.init(allocator, .{ .io = io, .path = "seed.yaml" });
defer gw.deinit();
const users = try zom.Relation(UserSchema, zom_yaml.WritableGateway).init(&gw);
_ = try users.create(.{ .id = 3, .name = "Wanjiru" }).commit();
try gw.sync();
```

- Records are written with their keys in schema order and null as `~`.
  Strings that another YAML reader would take as a number, bool or null
  are quoted (`"123"`, `"yes"`), as is anything that couldn't be read back
  plain.
- In a single file, the datasets this gateway didn't change are written
  back as the file holds them at sync time, in the same order and with the
  same quoting. The file is read again just before writing. A dataset new
  to the file goes last.
- **Comments and formatting are not kept** in the datasets that are
  rewritten.
- The write is atomic (temp file, fsync, rename), and a failed `sync`
  leaves the file untouched and the dataset dirty. `deinit` does not sync.

## Lower-level pieces

| Declaration | What it is |
|---|---|
| `zom_yaml.yaml.parseDatasets` / `parseRecords` | The parser on its own, for the two layouts. Returns records of scalar text plus an arena. |
| `zom_yaml.yaml.writeScalar` | Writes a key or value so that the parser reads back the same text. |
| `zom_yaml.writeRecords(w, T, rows, allocator)` | A bare sequence of tuples, the one-file-per-dataset layout. |
| `zom_yaml.writeDataset(w, T, name, rows, allocator)` | `name:` followed by its records, for building a single file. |

## Testing

```sh
zig build test-adapters   # includes zom_yaml's parser and gateway tests, and zom.lint
```
