# zom-tigerbeetle

A [zom](../../README.md) gateway for [TigerBeetle](https://tigerbeetle.com),
on its C client (`tb_client`). TigerBeetle tests zom's adapter contract
hardest: two fixed schemas, 128-bit ids, immutable records, batched writes
and limited queries (plan.md, Phase 6).

**Status:** scaffold (#54). The gateway starts the client, and the two
schemas and their datasets pass `zom.Adapter`. Inserts come in #55, and
reads in #56: until then, `read` and `count` return `error.Unimplemented`.

## Schemas

The schemas are fixed, and they use the client's own structs, not copies:

```zig
pub const Account = zom.Schema(tb.Account, "accounts", .id, .{});
pub const Transfer = zom.Schema(tb.Transfer, "transfers", .id, .{});
```

`tb.Account` and `tb.Transfer` are `tb_account_t` and `tb_transfer_t` from
`tb_client.h`. They are `extern struct`s of 128 bytes holding only plain
integers, with every field defaulting to 0:

| Field | Type |
|---|---|
| `id`, amounts / balances, `debit_account_id`, `credit_account_id`, `pending_id`, `user_data_128` | `u128` (zom's `Value.uint128`) |
| `user_data_64`, `timestamp` | `u64` |
| `user_data_32`, `ledger`, `timeout` (transfers), `reserved` (accounts) | `u32` |
| `code`, `flags` | `u16` |

In the C header `flags` is a plain `u16`, not a packed struct, so zom needs
no special support for it. For named bits, use `tb.AccountFlags` and
`tb.TransferFlags`, which are `packed struct(u16)`s of bools:

```zig
var account: tb.Account = .{ .id = 1, .ledger = 700, .code = 10 };
account.flags = tb.AccountFlags.bits(.{ .history = true });
const flags = tb.AccountFlags.of(account); // flags.history == true
```

A test checks that each flag's bit matches the header's `TB_*_FLAGS`
constant. The struct sizes, alignments and `extern` layout are asserted at
compile time, so a newer header that changes them won't build.

`Gateway.Dataset` also accepts a `zom.Schema` of your own over `tb.Account`
or `tb.Transfer` keyed by `.id`, for example to add plugins. Any other
struct is a compile error.

No `update`, no `delete`, no `transaction`: TigerBeetle records are
immutable, so `relation.update()` and `relation.delete()` don't compile.
Linked event chains will take the place of transactions (#58).

## Setup

zom-tigerbeetle is the `zom_tigerbeetle` module of the zom package. Its
client library is a lazy dependency, so it only exists when asked for:

```zig
const dep = b.dependency("zom", .{ .target = target, .optimize = optimize, .tigerbeetle = true });
exe.root_module.addImport("zom_tigerbeetle", dep.module("zom_tigerbeetle"));
```

In a checkout of zom, `-Dtigerbeetle` is on by default.
`zig build test-tigerbeetle` runs this module's tests. The one that talks
to a cluster is skipped unless `ZOM_TB_ADDRESSES` is set:

```sh
tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development 0_0.tigerbeetle
tigerbeetle start --addresses=3000 --development 0_0.tigerbeetle &
ZOM_TB_ADDRESSES=3000 zig build test-tigerbeetle
```

```zig
var gateway = try zom_tigerbeetle.Gateway.init(allocator, .{
    .io = io,
    .cluster_id = 0,
    .addresses = "3000", // or "10.0.0.1:3000,10.0.0.2:3000,10.0.0.3:3000"
});
defer gateway.deinit();
```

`init` starts the client, which connects in the background. An unreachable
cluster shows up on the first request, not in `init`. `init` only fails on
bad addresses (`error.InvalidAddress`), on OS resources, or when out of
memory.

## How the client is fetched (the dependency decision)

zom builds with Zig 0.16. There were three ways to reach TigerBeetle:

1. **A source dependency on the tigerbeetle repo, importing its Zig
   client.** Ruled out. TigerBeetle's releases pin their own Zig: the
   `0.17.9` and `0.17.10` tags use Zig 0.14.1, and only unreleased `main`
   was on 0.16.0 when this was decided (2026-11). The repo also isn't set up
   to be a dependency. It has no `build.zig.zon`, its `build.zig` exports
   only `stdx` (the client lives in the internal `vsr` module), and
   `build()` asserts a git commit, which a fetched tarball doesn't have.
2. **The C client through translate-c and a static library.** Chosen. The C
   ABI doesn't depend on which Zig built the library, so a `libtb_client`
   built by TigerBeetle's Zig links into a 0.16 program.
3. **The binary protocol, implemented in zom.** Not pursued. It would mean
   reimplementing VSR client sessions, and tracking TigerBeetle's
   wire-format changes forever.

TigerBeetle's GitHub releases don't ship `libtb_client`, but
[tigerbeetle-go](https://github.com/tigerbeetle/tigerbeetle-go) vendors it
in `native/` for every release tag. That gives one header, `tb_client.h`,
and these libraries:

| Target | Library |
|---|---|
| x86_64-linux, aarch64-linux | `libtb_client_<arch>-linux.a` |
| x86_64-macos, aarch64-macos | `libtb_client_<arch>-macos.a` |
| x86_64-windows | `tb_client_x86_64-windows.lib` (plus `ws2_32`, `ntdll`) |

zom's `build.zig.zon` pins that tarball (1.3 MB) at tag `v0.17.9`, and the
tag sets the client release. zom's `build.zig` translates the header with
the built-in `b.addTranslateC` (no translate-c package needed) and links
the library for the target. Any other target gets a build error that names
the supported ones. The module links libc, because the library uses libc
for its thread and its I/O.

This was checked before any adapter code was written: Zig 0.16.0 with the
`v0.17.9` library against a `tigerbeetle 0.17.9` dev server ran
`create_accounts`, then `lookup_accounts` with ids above `maxInt(u64)`.

To move to another client release, pick the tag that matches your cluster
(a client must be within the release range the cluster accepts):

```sh
# from the repo root; then put `.lazy = true` back on the tigerbeetle_go entry
zig fetch --save=tigerbeetle_go https://github.com/tigerbeetle/tigerbeetle-go/archive/refs/tags/v<release>.tar.gz
```

If TigerBeetle releases on Zig 0.16 later, option 1 could replace this. The
schemas would stay the same, because the Zig client's `Account` and
`Transfer` have the same layout. Only `flags` would become the packed
struct.
