# zom-csv

A [zom](../../README.md) gateway over CSV files. It is zom's version of
rom's `rom-csv`. Each dataset is one `.csv` file, named after the schema
(`users` is `users.csv`), and is loaded on first use into a
`zom.memory.Store(S)`. Queries then run exactly as they do in memory:
filters, `or` groups, `in`, `like`, ordering, offset and projection. Joins
are not supported.

There are two gateway types, because what an adapter can do is part of its
type in zom:

| Type | Datasets have | Use for |
|---|---|---|
| `zom_csv.Gateway` | `read`, `count` | Fixtures, seed data, lookups. A `create`, `update` or `delete` is a compile error naming the `csv` adapter. |
| `zom_csv.WritableGateway` | also `insert`, `insertMany`, `update`, `delete`, `sync` | Files the program edits. Writes change the memory store, and `sync()` writes them back. |

Both pass `zom.lint`. [examples/csv_users](../../examples/csv_users) puts
a CSV gateway beside a memory one in a single container.

## Setup

zom-csv is the `zom_csv` module of the zom package and depends on nothing
else:

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zom", dep.module("zom"));
exe.root_module.addImport("zom_csv", dep.module("zom_csv"));
```

```zig
const zom = @import("zom");
const zom_csv = @import("zom_csv");

const User = struct { id: u32, name: []const u8, email: []const u8, age: ?u8 = null };
const UserSchema = zom.Schema(User, "users", .id, .{});

var gw = zom_csv.Gateway.init(allocator, .{ .io = io, .path = "data" });
defer gw.deinit();
const users = try zom.Relation(UserSchema, zom_csv.Gateway).init(&gw);

const adults = try users.where(.age, .gte, 18).order(.name, .asc).toSlice(allocator);
defer allocator.free(adults);
```

`init` only records the config. Nothing is read until the first
`dataset(S)` call, which `Relation.init` makes.

| `Config` field | Default | |
|---|---|---|
| `io` | required | The `std.Io` that does the file I/O. |
| `path` | required | A directory of `<name>.csv` files, or one CSV file whose stem is the dataset name. Borrowed. |
| `dir` | `.cwd()` | What a relative `path` is resolved against. Must stay open as long as the gateway. |
| `separator` | `','` | Use `'\t'` for TSV, `';'` for European exports. |
| `null_text` | `""` | The cell text that means `null` for an optional field. |
| `unknown_columns` | `.reject` | `.ignore` skips columns the schema doesn't have (read-only gateway only). |
| `max_file_bytes` | 64 MiB | A larger file is `error.FileTooBig`. |
| `line_ending` | `"\n"` | What `sync` ends each row with. Reading accepts `\n` and `\r\n` either way. |

## Finding the file

- If `path` is a directory, the dataset `users` is `<path>/users.csv`.
- If `path` is a file, it holds only the dataset named after its stem:
  `data/users.csv` holds `users`, and any other schema is
  `error.NotFound`.
- A missing file is `error.NotFound` on `Gateway`. On `WritableGateway` it
  is an empty dataset, and the first `sync` after a write creates the
  file. A writable gateway also accepts a `path` ending in `.csv` that
  doesn't exist yet.

## Loading

The file is read whole, and a leading UTF-8 byte order mark is skipped.

1. **The first row is the header.** Columns can come in any order. Every
   field that is neither optional nor defaulted needs a column. A missing,
   unknown or repeated column is `error.SchemaMismatch`, and every problem
   is listed in one message. `WritableGateway` rejects unknown columns even
   with `.ignore`, because `sync` would drop them.
2. **Every other row is decoded** with `zom.codec` (the same rules as every
   adapter that reads text):

   | Field type | Accepted cell text |
   |---|---|
   | integers | decimal, optional sign, `_` between digits; out of range is `error.ValueOutOfRange` |
   | floats | decimal, hex, exponents, `inf`, `nan` |
   | `bool` | `true` `false` `1` `0` `t` `f`, any case |
   | enums | the tag name, exact case |
   | `[]const u8` | anything, copied into the store |
   | `?T` | `null_text` is `null`, anything else decodes as `T` |

   Whitespace is never trimmed. An empty cell in a non-optional integer
   column is `error.UnexpectedNull`, not "not an integer".
3. Blank lines are skipped. A row with a different number of cells than the
   header is `error.WrongCellCount`. Duplicate primary keys are not checked
   on load, because the file is the source of truth.

The parser is RFC 4180. A quoted cell can hold the separator, line breaks,
and doubled quotes (`"say ""hi"""`). A stray quote is
`error.UnexpectedQuote`, and a quote that never closes is
`error.UnterminatedQuote`.

### Diagnostics

Zig errors carry no data, so every load or sync error also leaves a
one-line message in `gw.diagnostic`, prefixed with the file and, for a row,
`line:cell`:

```zig
_ = zom.Relation(UserSchema, zom_csv.Gateway).init(&gw) catch |err| {
    std.log.err("{t}: {s}", .{ err, gw.diagnostic.message() });
    return err;
};
// SchemaMismatch: data/users.csv: header does not match 'users': unknown column "nickname"
// InvalidInt:     data/users.csv:3:4 (age): "abc" is not an integer from 0 to 255
```

A failed load is not remembered, so the next `dataset(S)` call tries again.

## Writing back

```zig
var gw = zom_csv.WritableGateway.init(allocator, .{ .io = io, .path = "data" });
defer gw.deinit();
const users = try zom.Relation(UserSchema, zom_csv.WritableGateway).init(&gw);

_ = try users.create(.{ .id = 4, .name = "Otieno", .email = "otieno@example.com" }).commit();
_ = try users.byPk(2).update().set(.age, 40).commit();

try gw.sync(); // every dirty dataset; or `(try gw.dataset(UserSchema)).sync()` for one
```

- Writes follow the memory adapter's rules: a duplicate primary key is
  `error.DuplicatePrimaryKey`, and `createMany` is all or nothing.
- `sync` writes each dirty dataset to `<file>.tmp` in the same directory,
  flushes and fsyncs it, and renames it over the original. A reader sees
  either the old file or the new one, and the file keeps its permissions.
  On any error the original is untouched and the dataset stays dirty, so
  you can retry `sync`.
- Columns keep the order of the header read at load time. Fields that
  header lacked follow, in schema order, and a new file uses schema order.
  Cells holding the separator, a quote or a line break are quoted.
- **`deinit` does not sync.** Unsynced writes are dropped, as in rom-csv,
  where nothing reaches the file without `sync!`.
- Only one process should write a given file at a time, because two
  processes syncing the same file share the temp file name.

## Lower-level pieces

| Declaration | What it is |
|---|---|
| `zom_csv.csv.Reader` | The RFC 4180 reader on its own: `init(allocator, text, .{ .separator })`, then `next()` per row. Cells without escapes borrow from the input, so most rows need no allocation. |
| `zom_csv.csv.writeRow` | Writes one row, quoting only where needed. |
| `zom_csv.writeTable(writer, T, rows, allocator, options)` | Writes a header of `T`'s field names and one row per tuple, in the format the gateway reads back. Handy for generating fixtures. |
| `zom_csv.Format` | The CSV `Format` handed to `zom.file.Gateway`. zom-yaml is built the same way; see [Writing an adapter](../../docs/adapters.md#writing-an-adapter). |

## Testing

```sh
zig build test-adapters   # includes zom_csv's tests and zom.lint on both gateways
```
