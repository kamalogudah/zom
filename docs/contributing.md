# Contributing

New contributors are welcome, including people who are new to Zig. Work is
tracked as [GitHub issues](https://github.com/kamalogudah/zom/issues), grouped
into [milestones](https://github.com/kamalogudah/zom/milestones) that follow the
phases in [plan.md](../plan.md). Every ticket lists the Zig concepts it needs, with
links to the topics below.

## 1. Set up

1. Install **Zig 0.17.1** (`build.zig.zon` sets `minimum_zig_version = "0.17.1"`; 0.17.0 has bugs fixed in 0.17.1). Get it from https://ziglang.org/download/, or use a version manager like [`zvm`](https://github.com/tristanisham/zvm) or [`anyzig`](https://github.com/marler8997/anyzig).
2. Check it: `zig version` should print `0.17.1`.
3. Clone and run the tests:
   ```sh
   git clone git@github.com:kamalogudah/zom.git
   cd zom
   zig build test
   ```
   If nothing is printed and the exit code is 0, every test passed. Add `--summary all` to see each step.
4. Editor support: install [ZLS](https://github.com/zigtools/zls) built for 0.17, which gives you go-to-definition into the standard library. That's the fastest way to learn the std API. (Zig 0.17 removed the build runner override ZLS relied on, so check that your ZLS release supports 0.17.)

## 2. A tour of the code (about 1,400 lines, a third of them tests)

| File | What it does | Read it for |
|---|---|---|
| `src/root.zig` | Public API: re-exports everything | How a Zig package exposes modules |
| `src/schema.zig` | `Schema(T, name, pk)` returns a type | Functions that return types (generics) |
| `src/query.zig` | `Value` union, `Query(T)`, filter matching, compile-time type checks | Tagged unions, `@typeInfo`, `@compileError` |
| `src/adapter.zig` | `Adapter(G)`: checks the adapter contract and finds a gateway's capabilities | `@hasDecl`, `@typeInfo(...).@"fn"`, building comptime strings |
| `src/lint.zig` | `lint.run(G, Factory)`: the conformance suite every adapter runs | Tests as library code, `inline for` over a tuple of generic functions |
| `src/relation.zig` | `Relation(S, Gateway)`: immutable query builder | Comptime field enums, `anytype`, a type parameter with a default through a wrapper (`Relation` calls `RelationOf`) |
| `src/projection.zig` | `Project(T, fields)`: the narrower struct `select` reads into | `@Struct`, field defaults in reflection, memoised comptime calls |
| `src/container.zig` | `Container(spec)`: gateways and relations declared once, init/deinit in one place | Building struct types with `@Struct`, `errdefer` with a counter in an `inline for` |
| `src/repository.zig` | `Repository(App, spec)`: a root relation with command shortcuts, and wrapper structs for custom views | `@Struct`, `@FieldType`, `@TypeOf` in return types, forwarding methods by hand |
| `src/changeset.zig` | `Create`, `CreateMany` and `Update` changesets | Fixed-capacity arrays, slices, comptime capability branching |
| `src/mapper.zig` | Copies tuples into domain structs | `inline for` over struct fields |
| `src/codec.zig` | Text cells to typed fields and back, with a `Diagnostic` out-parameter | `@typeInfo` dispatch, mapping error sets with `catch \|e\| switch`, the diagnostics pattern, `std.Io.Writer` and shortest round-trip float formatting |
| `src/adapters/memory.zig` | In-memory gateway and dataset | Allocators, arenas, `ArrayList`, hash maps, type erasure with `*anyopaque` |
| `src/tests/` | Tests, one file per layer, with shared `fixtures.zig` | `std.testing` |
| `examples/readme.zig` | Every code block in README.md and docs/, compiled by `zig build test` | Using zom as a package import |
| `examples/csv_users/` | A program joining CSV users with in-memory posts through `zom.Container`, run and checked by `zig build test` | `b.addExecutable`, `pub fn main(init: std.process.Init)`, writing to stdout |
| `tests/compile_errors/` | Code that must *not* compile, checked by `zig build compile-errors` | What `@compileError` messages users see |
| `src/file.zig` | `zom.file`: the gateway and datasets file adapters share, over a `Format` (load and dump) | Comptime-parameterised generics, duck typing checked with `@hasDecl`/`@hasField`, atomic writes (temp file, fsync, rename) |
| `adapters/csv/` | The `zom_csv` module, a CSV `Format` for `zom.file` | Modules and imports in `build.zig`, `b.dependency(...).module(...)` |
| `adapters/sql/` | The `zom_sql` module: compiles a query to SQL for a comptime `Dialect` | Comptime struct parameters, rendering into a `*std.Io.Writer`, recursion with an explicit error set, multiline string literals in tests |
| `adapters/yaml/` | The `zom_yaml` module: a YAML-subset parser and writer, and a YAML `Format` for `zom.file` | A hand-written line parser, arenas, escaping that round-trips |

## 3. Zig concepts used everywhere in zom

The language reference for this version is https://ziglang.org/documentation/0.17.1/ (called **langref** in the tickets). Also useful: [ziglang.org/learn](https://ziglang.org/learn/), and the standard library source, which lives under `lib/std/` next to your `zig` binary (`zig env` prints the path).

- **Comptime and generic types.** `Schema`, `Query`, `Relation` and `Mapper` are all *functions that return a `type`*. They run at compile time. See langref [comptime](https://ziglang.org/documentation/0.17.1/#comptime) and [Generic Data Structures](https://ziglang.org/documentation/0.17.1/#Generic-Data-Structures).
- **Reflection.** `@typeInfo(T)` returns a tagged union describing a type (struct fields, int signedness and bits, optional child type and so on). zom uses it to inspect your tuple struct. Since 0.17 a struct's fields are parallel arrays: `inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs|`, with `attrs.defaultValue(F)` for a default. See [@typeInfo](https://ziglang.org/documentation/0.17.1/#typeInfo), [@FieldType](https://ziglang.org/documentation/0.17.1/#FieldType), [@field](https://ziglang.org/documentation/0.17.1/#field), [@hasDecl](https://ziglang.org/documentation/0.17.1/#hasDecl) and [@hasField](https://ziglang.org/documentation/0.17.1/#hasField).
- **`inline for` and `inline else`.** These unroll a loop or a switch at compile time, so every iteration can use a different type. `switch (field) { inline else => |tag| ... }` turns a runtime enum value into a comptime one. See [inline for](https://ziglang.org/documentation/0.17.1/#inline-for) and [Inline Switch Prongs](https://ziglang.org/documentation/0.17.1/#Inline-Switch-Prongs).
- **Custom compile errors.** `@compileError("...")` is how zom rejects bad queries at build time. See [@compileError](https://ziglang.org/documentation/0.17.1/#compileError).
- **Errors.** `!T`, `try`, `catch`, `errdefer`, error sets and inferred error sets. See [Errors](https://ziglang.org/documentation/0.17.1/#Errors) and [errdefer](https://ziglang.org/documentation/0.17.1/#errdefer).
- **Allocators.** Nothing allocates behind your back. Any function that returns heap memory takes a `std.mem.Allocator`, and the caller frees the result. In tests, use `std.testing.allocator`, which fails the test if you leak memory. See [Memory](https://ziglang.org/documentation/0.17.1/#Memory) and [Choosing an Allocator](https://ziglang.org/documentation/0.17.1/#Choosing-an-Allocator).
- **Unmanaged containers.** Since 0.16, `std.ArrayList(T)` doesn't store its allocator. You start it with `.empty` and pass the allocator to each call: `list.append(gpa, x)`, `list.deinit(gpa)`.
- **Tagged unions.** `Value` is `union(enum)`. Use `switch` to read it. See [Tagged union](https://ziglang.org/documentation/0.17.1/#Tagged-union).
- **Optionals.** `?T`, `orelse`, `if (x) |v|`. See [Optionals](https://ziglang.org/documentation/0.17.1/#Optionals).
- **Tests.** `test "name" { ... }` blocks, `try std.testing.expectEqual(...)`. See [Zig Test](https://ziglang.org/documentation/0.17.1/#Zig-Test).
- **Build system.** `build.zig` and `build.zig.zon`. See [Zig Build System](https://ziglang.org/learn/build-system/).

## 4. How we work

- Pick an issue in the earliest open milestone, and comment on it to claim it. Tickets labelled `difficulty: beginner` are the best first ones.
- One issue per PR. Reference it with `Closes #N`.
- `zig build test` must pass, and run `zig fmt src` (or `zig fmt .`) before you push.
- Follow the project's principles ([plan.md](../plan.md) section 6): compile-time checks first, explicit fixed limits, relations stay plain values, callers own allocations, and adapters must pass `zom.lint`.
- Match the surrounding style: doc comments (`//!` at file level, `///` on declarations) explain *why*, and the rom equivalent is named where there is one.
- Stuck? Comment on the issue with what you tried and the exact compiler error. Zig's errors usually point at the right line, so include the whole message.

## Compile-error tests

Many of zom's guarantees are things that don't compile, and `zig test` can't express that. Each file in `tests/compile_errors/` imports `zom`, does one illegal thing, and starts with the error text it must produce:

```zig
// expect: zom: attribute 'age' is not optional, null is not allowed
const std = @import("std");
const zom = @import("zom");

const User = struct { id: u32, age: u8 };
const Users = zom.Relation(zom.Schema(User, "users", .id, .{}), zom.memory.Gateway);

export fn entry() void {
    var gw = zom.memory.Gateway.init(std.heap.page_allocator, .{});
    const users = Users.init(&gw) catch return;
    _ = users.where(.age, .eq, null);
}
```

`zig build compile-errors` (also run by `zig build test`) compiles every case and fails if one compiles, or if its stderr doesn't contain the `// expect:` text. For a multi-line error, start the file with several `// expect:` lines (one per line of the message, without its indentation); each must appear in stderr, as in `adapter_missing_decls.zig`. To add a case, drop a new `.zig` file in the folder; `build.zig` picks it up. Put the illegal code inside an `export fn` so the compiler analyzes it, and copy the expected text from the real error (types declared in the case show up as `<file name>.<Type>`). The cases build zom with `-Dno-deprecated` on, so a case can't lean on a deprecated declaration, and `combine_many_deprecated.zig` checks that error. To reproduce one by hand, give zom its `build_options` module:

```sh
echo 'pub const no_deprecated: bool = true;' > /tmp/build_options.zig
zig build-obj -fno-emit-bin --dep zom -Mroot=tests/compile_errors/null_on_non_optional.zig \
  --dep build_options -Mzom=src/root.zig -Mbuild_options=/tmp/build_options.zig
```

## 5. Good first tickets

Look for the [`good first issue`](https://github.com/kamalogudah/zom/labels/good%20first%20issue) label in the **Phase 0** milestone. Those tickets fix real bugs in code under 300 lines long, and each one comes with a failing test you can write first.
