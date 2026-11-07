# API (v0.2)

This is the public API as of 0.2.0: everything `src/root.zig` exports.
Adapters written from Phase 1 on build against it. While zom is on `0.x`, a
breaking change needs a minor version bump and an entry in
[CHANGELOG.md](../CHANGELOG.md). The changes already planned are scheduled in
[plan.md](../plan.md).

## Exports

| Declaration | What it is |
|---|---|
| `zom.Schema(T, name, pk, options)` | Returns a schema type with `Tuple = T`, `name` (the dataset name), `primary_key` (a field of `T`, as an enum literal) and its associations. `pk` may be `null` for a view with no single unique field (see [Views](associations.md#views-schemas-without-a-primary-key)): `has_primary_key` is then false. `options` is `.{}`, or has `.associations` (see [Associations](associations.md#associations)) and `.plugins` (see [Plugins](containers.md#plugins)). |
| `zom.hasMany(Target, .fk)`, `zom.belongsTo(Target, .fk)` | Declare an association on a schema. `S.association(.name)` and `S.associations.name` return a `zom.Association`: `name`, `kind` (`zom.AssociationKind`: `has_many`, `belongs_to` or `custom`), `source`, `target`, `foreign_key` and `primary_key` (field names as strings), `cardinality` (`zom.Cardinality`: `.many` or `.one`) and `tag`, plus `Child()`, `Parent()` and `Key()` (the key type a combine groups by). |
| `zom.customAssociation(Target, .tag, .many)` | Declare an association with no foreign key zom can use, whose rows `Target`'s dataset finds itself through `loadAssociation`. `.one` instead of `.many` for an optional. See [Custom associations](associations.md#custom-associations-and-loadassociation). |
| `zom.Relation(S, Gateway)` | Returns an immutable relation type over schema `S` and an adapter's `Gateway`. Checks the [adapter contract](adapters.md#the-adapter-contract) at compile time through `zom.Adapter(Gateway)`, which it exposes as `Relation.Adapter`. |
| `zom.RelationOf(S, Gateway, Output)` | The strict relation type whose reads return `Output`. `Relation(S, G)` is `RelationOf(S, G, S.Tuple)`, and `select` returns `RelationOf(S, G, Project(S.Tuple, fields))`. Exposes `Tuple`, `Output`, `projected` and `mode`. |
| `zom.RelationWith(S, Gateway, Output, mode)` | The relation type with every parameter. `RelationOf(S, G, Out)` is `RelationWith(S, G, Out, .strict)`, and `allowFallback()` returns `RelationWith(S, G, Out, .fallback)`. |
| `zom.Mode` | `strict` or `fallback`: what a relation does with query features its dataset does not support. See [Query support](#query-support-strict-and-fallback). |
| `zom.Scan`, `zom.ScanHook` | What a `.fallback` read that ran in memory reports (`adapter`, `relation`, `rows_fetched`, `rows_returned`), and the `*const fn (Scan) void` it reports to. |
| `zom.Project(T, .{ fields })` | The struct `select` reads into: only `fields` of `T`, in the order given, with their types and defaults. An empty tuple, an unknown field or a repeated one is a compile error. Equal arguments return the same type. |
| `zom.Adapter(G)` | Checks gateway `G` against the [adapter contract](adapters.md#the-adapter-contract), reporting every problem in one compile error. Has `Gateway`, `name` (`G.adapter_name`), `Dataset(S)` (checks the dataset for schema `S`), `capabilities(S) Capabilities`, `has(S, cap) bool`, `readOnly(S) bool`, `require(S, cap, method)`, `supports(S) Supports`, and `filterGap(S, field, op)` / `orderGap(S, field)`, which return null when the dataset can evaluate that filter or sort key, else why not. |
| `zom.Supports` | The query features a dataset evaluates itself: `or` (boolean groups), `in` (`in`, `not_in`), `like` (`like`, `ilike`), `order_on` (order by any attribute, not only the key), `offset`, `projection`, `join` (`relation.join`), `per_group_limit` (`read` and `readProjected` page each group of `query.per_group`, and `loadAssociation` each key's slice, so `combine` pushes a target's per-parent page down; checked by `zom.lint`). `Supports.all` sets them all. |
| `zom.Join`, `zom.JoinFilter` | What `relation.join(.assoc)` stores in `query.join`: the association's name, the joined table, the key column on each side and its joined filters, each by column name: up to `Join.max_filters = 8` filters in `Join.max_nodes = 16` nodes, as the same flat tree a `Query` uses (`zom.query.FilterNode`; read it from `topNodes()`, or through `filterSlice()` when `isConjunction()`). Plain data, so a query is still copied by value without allocating; `join.targetQuery(C)` gives the filters back, groups and all, as a `zom.Query(C)`. Only an adapter with `supports.join` reads it. |
| `zom.Capability` | `writable`, `batch_insert`, `updatable`, `deletable`, `transaction`. |
| `zom.StringOwnership` | `dataset` or `caller`: who frees the strings in the tuples a dataset returns. See [Memory rules](memory.md#memory-rules). |
| `zom.strings` | Helpers for caller-owned strings: `freeFields(T, allocator, item, keep)` frees an item's string attributes except those named in `keep`, `freeAll(T, allocator, items)` frees every item's strings and the slice, and `dupeFields(T, allocator, item)` copies them (freeing its copies on error). |
| `zom.Capabilities` | A struct with one `bool` per `Capability`, all `false` by default. |
| `zom.adapter` | The module behind `Adapter`, `Capability` and `Capabilities`. |
| `zom.Query(T)` | The adapter-neutral query a relation builds: a filter tree, sort keys (`orders`, at most `max_orders = 4`, read through `orderSlice()`, most significant first), `limit: ?usize`, `offset: usize`, `per_group: ?Field` (set by `combine` on a dataset with `supports.per_group_limit`: the limit and offset then page each group of rows sharing that attribute's value, nulls as one group; `pageGroups(rows, scratch)` applies the page to rows in memory, per group or not), and `all: bool` (default false: set it to say an update or delete with no filters is meant to touch every row, which [zom-sql](../adapters/sql/README.md) otherwise refuses; it changes nothing about which rows match). The tree is stored flat so a copy is a full copy: `filters` (at most `max_filters = 16`) and `nodes` (at most `max_nodes = 32`: filters plus `any` / `all` / `not` groups, which refer to children by index), AND-ed at the top level. An adapter without `or` support reads an AND-only query through `filterSlice()` (it asserts `isConjunction()`); one with it walks `nodeSlice()` from `topNodes()`. `matches(row)` and `truth(row) ?bool` evaluate the query in memory with SQL's three-valued logic, alongside `lessThan(orders, a, b)` (the comparator for `std.mem.sort(T, rows, query.orderSlice(), lessThan)`: key by key, the next key breaking ties), `orderBy(order, a, b)` (one key) and `fieldValue(row, field)`. Nested types: `Field` (enum of `T`'s fields), `Filter` (`field`, `op`, `operand`), `Node` (`filter`, `and_group`, `or_group`, `not`), `Children`, `Order`, `Change`. `max_in = 64` bounds one `in` list. The query also builds itself, with the same `where` / `whereIn` / `whereNotIn` / `whereAny` / `whereNot` / `order` / `reorder` as a relation (and `addOrder`), so adapters and tests can make one without a gateway. |
| `zom.any(conds)`, `zom.all(conds)`, `zom.not(cond)` | Boolean groups to nest inside `whereAny` / `whereNot`. A condition is `.{ field, op, value }` or another group. |
| `zom.Value` | The runtime value carried by filters and changes. See [Value](#value). |
| `zom.Op` | Filter operators: `eq`, `neq`, `lt`, `lte`, `gt`, `gte`, `in`, `not_in`, `like`, `ilike`, `between`, `is_null`, `is_not_null`. `op.operand()` returns the `Operand` variant it takes. |
| `zom.Direction` | `asc`, `desc`. |
| `zom.Container(spec)` | Declares gateways and relations once; `init(self, allocator, Config)` / `deinit()` connect and disconnect them all. See [Container](containers.md#container). |
| `zom.Repository(App, .{ .root, .relations })` | Groups some of a container's relations around a root relation: `init(&app)`, `relations` (one field per relation, or its wrapper struct), `root()`, and the root shortcuts `byPk`, `where`, `all`, `create`, `createMany`, `update`, `delete`. See [Repository](containers.md#repository). |
| `zom.plugins` | Schema plugins: `timestamps(.{ .created, .updated, .unit })`, the `Context` and `Clock` hooks read, `ChangeList(T)` (what `beforeUpdate` hooks edit) and `max_changes`. See [Plugins](containers.md#plugins). |
| `zom.changeset` | `Create(Rel)`, `CreateMany(Rel)`, `Update(Rel)` and `Scoped(Rel, keys)`, the types returned by `relation.create`, `relation.createMany`, `relation.update` and `relation.associate`. You don't name them yourself; `Scoped`'s `Input` is the struct its `create` takes. |
| `zom.Mapper(Src, Dst, .{ .renames })` | A comptime mapper: `call(src) Dst` and `many(allocator, srcs) ![]Dst`. A `Dst` field takes the `Src` field of the same name (or its rename), else its default; neither is a compile error. Every field is set. `sources` lists the `Src` fields it copies, and `options` the options it was made with. |
| `zom.Combined(Source, association, Target)`, `zom.CombineResult(E)` | What `relation.combine(.assoc, target)` returns, and what its `mapTo` / `mapWith` return: `items: []E` and the arena owning them, freed with `deinit()`. See [Associations](associations.md#associations). |
| `zom.combineMany(.{ .into, .parent_key, .child_key }, allocator, parents, children)` | **Deprecated:** use `relation.combine`. Sets `parent.into` to the children whose `child_key` equals the parent's `parent_key`, on slices already loaded, in O(n·m). Build with `-Dno-deprecated` to make each call a compile error. |
| `zom.mapper` | The module behind `Mapper` and `combineMany`, with their option types `Options`, `Rename` and `CombineOptions`, and `isMapper(M)`, true when `M` was made by `zom.Mapper`. |
| `zom.codec` | Text cells to field values, for adapters whose rows arrive as strings. `decodeField(F, text, opts) !F` decodes one cell, and `decodeRow(T, cells, opts, ?*Diagnostic) !T` decodes a row, in field order or through `Options.columns`. `Options.null_text` (default `""`) means null. Strings borrow the cells. On error the `Diagnostic` has `row`, `column`, `field`, `text` and `err`, and formats with `{f}` as `14:3 (age): "abc" is not an integer from 0 to 255`. The other way, `encodeField(writer, value, opts)` and `encodeRow(writer, T, row, opts, sep)` write values back so they decode to the same thing: ints `{d}`, floats in their shortest round-trip form (decimal, or scientific outside `1e-6`..`1e21`), `true`/`false`, tag names, strings as they are, `null` as `null_text`. Nothing is quoted; that is the format writer's job. The accepted spellings are listed in `src/codec.zig`. |
| `zom.memory` | The in-memory adapter: `Gateway` (`adapter_name = "memory"`, `Config = struct {}`, `init(allocator, Config)`, `deinit()`), whose dataset is `Store(S)`. Every capability; its `transaction` saves each store's rows and puts them back on error, for tests without a database. |
| `zom.memory.Store(S)` | The in-memory row engine, usable without a gateway: `init(allocator)`, `deinit()`, `read`, `count`, `insert`, `insertMany`, `update`, `delete`, plus `rows() []const Tuple` (every row, in insertion order), `load(row)` and `loadMany(rows)` (insert without the primary-key check, for trusted bulk loads) and `clear()`. Strings are copied into the store's arena; rows it returns point into it until `clear` or `deinit`. |
| `zom.lint` | The adapter conformance suite, see [Checking an adapter](adapters.md#checking-an-adapter-with-zomlint). Also exports the schema it tests on, `Users` (`User`, `Role`), its seed rows, `users`, `OnDuplicate` and `expectSharedError`. |
| `zom.query` | The module behind `Query`, `Value`, `Op` and `Direction`, plus `Operand` (a filter's value side: `none`, `one`, `many: ValueList` or `range: [2]Value`), `ValueList` (a borrowed list read with `at(i)`) and `like(text, pattern, case)`, the `LIKE` matcher `matches` uses. Adapters can use `toValue(x) Value` and `fromValue(F, value) !F` to convert between attribute values and `Value`. Its `assert*`, `isString` and `isComptimeOnly` helpers are used by the core and are not part of the frozen API. |

## Relation

`users` below is a `zom.Relation(S, Gateway)`. Building methods return a new
relation and never touch the dataset. `field` is always an enum literal, and
`value` is type-checked against the attribute at compile time.

| Method | Returns | Notes |
|---|---|---|
| `Relation.init(*Gateway)` | `!Relation` | Asks the gateway for the schema's dataset. |
| `where(field, op, value)` | `Relation` | Filters are AND-ed. `op` is comptime, and decides what `value` is (below). `eq null` / `neq null` are aliases of `is_null` / `is_not_null`. |
| `whereIn(field, slice)`, `whereNotIn(field, slice)` | `Relation` | `in` / `not_in` over a runtime slice (or pointer to an array) of the attribute's type, at most `max_in` long. Borrowed, not copied. |
| `whereAny(.{ cond, ... })` | `Relation` | AND-s the conditions OR-ed together: `whereAny(.{ .{ .age, .gt, 30 }, .{ .role, .eq, .admin } })`. A condition is `.{ field, op, value }`, checked like `where` (a runtime slice works for `in`), or a nested `zom.any`, `zom.all` or `zom.not`. A condition too big for `max_filters` / `max_nodes` is a compile error; running out of room at runtime panics. |
| `whereNot(cond)` | `Relation` | AND-s NOT `cond`. SQL's three-valued logic: where `cond` is unknown (`NULL > 30`), so is its negation, and the row matches neither. |
| `byPk(value)` | `Relation` | `where(primary_key, .eq, value)`. A compile error on a view (no primary key). |
| `order(field, direction)` | `Relation` | Adds a sort key after those already set: `.order(.role, .asc).order(.age, .desc)` is `ORDER BY role ASC, age DESC`. At most `Query.max_orders = 4` keys; a fifth panics. |
| `reorder(.{ .{ field, direction }, ... })` | `Relation` | Replaces every sort key; `reorder(.{})` removes the order. More than `max_orders` keys is a compile error. |
| `limit(n)`, `offset(n)` | `Relation` | `n: usize`. |
| `page(n).perPage(k)` | `zom.pagination.Page(Relation)` | Page `n` (from 1) of `k` rows: `offset((n - 1) * k).limit(k)`. Its `toSlice(allocator)` reads the rows, and `paginate(allocator)` the rows with the total. See [Pagination](#pagination). |
| `select(.{ field, ... })` | a projected relation | Reads return `zom.Project(Tuple, fields)` instead of `Tuple`. See [Projections](#projections). |
| `allowFallback()` | a `.fallback` relation | Query features the dataset does not support compile, and run in memory. See [Query support](#query-support-strict-and-fallback). |
| `onScan(hook)` | `Relation` | The same relation, reporting in-memory reads to `hook` (a `zom.ScanHook`, or null). A `Container` sets it for you. |
| `toSlice(allocator)` | `![]Output` | Caller frees, with `free(allocator, rows)` to work on any adapter (see [Memory rules](memory.md#memory-rules)). `Output` is `Tuple`, or the projected struct after `select`. |
| `one(allocator)` | `!?Output` | `null` when empty, `error.MoreThanOneTuple` when ambiguous. Free the tuple with `freeOne(allocator, tuple)`. |
| `first(allocator)` | `!?Output` | Free like `one`. |
| `free(allocator, rows)` | `void` | Frees what `toSlice` returned: the slice, and its strings when the adapter's strings are caller-owned. |
| `freeOne(allocator, tuple)` | `void` | Frees a tuple's strings when they are caller-owned; a no-op on `.dataset` adapters. |
| `count()` | `!usize` | The number of rows `toSlice` would return, so `limit` and `offset` apply. On a `.fallback` relation it is `count(allocator)`, because it may have to read the rows to count them. |
| `mapTo(E, allocator)` | `![]E` | `mapWith(zom.Mapper(Output, E, .{}))`. |
| `mapWith(M, allocator)` | `![]M.Output` | `M` is a `zom.Mapper` whose `Input` is `Output`. |
| `combine(.assoc, target)` | `zom.Combined(...)` | This relation with association `assoc` of its schema, read from `target`, a relation over the association's target schema, or a combine of one for nested levels. Lazy; its `mapTo(E, allocator)` and `mapWith(M, allocator)` return a `zom.CombineResult(E)`. See [Associations](associations.md#associations). |
| `join(.assoc)` | `Relation` | The rows that have at least one row of association `assoc`, each once, as the same relation type. Needs `supports.join` (a compile error otherwise, even on a `.fallback` relation). See [Join](associations.md#join). |
| `whereJoined(.assoc, field, op, value)` | `Relation` | A filter on the joined rows, typed like `where` on the target's tuple. Needs `join(.assoc)` first. |
| `whereJoinedIn(.assoc, field, values)`, `whereJoinedNotIn(...)` | `Relation` | `whereIn` / `whereNotIn` on the joined rows: a runtime slice, borrowed, at most `max_in` long. |
| `whereJoinedAny(.assoc, conds)`, `whereJoinedNot(.assoc, cond)` | `Relation` | `whereAny` / `whereNot` on the joined rows. Needs `supports.or` on the joined dataset. |
| `create(tuple)` | `Create` | `.map(f)` applies `f: fn (Tuple) Tuple`; `.associate(.assoc, parent)` overwrites the tuple's foreign key from `parent`; `.commit()` returns `!Tuple`, the stored tuple. `.commitAlloc(allocator)` does the same on every adapter, allocating the returned strings when they are caller-owned (zom-pg, where plain `commit()` is a compile error); free the result with `freeOne`. A compile error after `select`. |
| `createMany(tuples)` | `CreateMany` | A compile error after `select`. `tuples: []const Tuple`, borrowed until commit. `.commit()` returns `!usize`, the rows inserted. Uses the dataset's `insertMany`, else loops over `insert` (see [the adapter contract](adapters.md#the-adapter-contract)). `.associate(.assoc, parent)` sets every tuple's foreign key on a copy, so the changeset then commits with `.commitAlloc(allocator)`. |
| `associate(.assoc, parent)` | `zom.changeset.Scoped(...)` | Sets the foreign key of `belongsTo` association `assoc` from `parent`, the target's tuple or a `select` of it that kept the key. Its `create(data)` and `createMany(rows)` take `Input`, the tuple without that key; chain `.associate` for more associations. Its `createMany` commits with `commitAlloc(allocator)`. A compile error after `select`. See [Associated creates](associations.md#associated-creates). |
| `update()` | `Update` | `.set(field, value)` adds a change (at most `max_changes = 16`); `.commit()` returns `!usize`, the rows changed. |
| `delete()` | `!usize` | The rows removed. |

On a `.fallback` relation, `update().commit()` and `delete()` return
`error.UnsupportedFilter` when the dataset can't evaluate every filter:
writes never run in memory. Joined writes use the same semi-join selection
as joined reads.

What `where` takes for each op. Every value is type-checked against the
attribute, and a comptime value (`.c`, `300`) must fit it.

| `op` | `value` | Example |
|---|---|---|
| `eq`, `neq`, `lt`, `lte`, `gt`, `gte` | a value, or `null` on an optional attribute | `where(.age, .gte, 18)` |
| `in`, `not_in` | a tuple of comptime-known values, at most `max_in` (64) | `where(.id, .in, .{ 1, 2, 3 })` |
| `like`, `ilike` | a string pattern, on string attributes only | `where(.name, .like, "Ach%")` |
| `between` | `.{ lo, hi }`, both inclusive | `where(.age, .between, .{ 18, 30 })` |
| `is_null`, `is_not_null` | `{}`, on an optional attribute | `where(.deleted_at, .is_null, {})` |

Nulls follow SQL: a null attribute only matches `is_null` / `is_not_null`.
`NULL IN (...)`, `NULL NOT IN (...)` and `NULL LIKE ...` never match, a null
inside an `in` list equals nothing and makes `not_in` match nothing, and an
empty `in` list matches nothing. In a `like` pattern, `%` matches any run of
characters, `_` one UTF-8 character, and `\` escapes the next one (`\%`,
`\_`, `\\`); `ilike` folds ASCII case only. Building a query never
allocates: a tuple's values become a static array, and `whereIn` borrows the
slice.

The relation's fields `dataset` and `query` are public too, so a relation
can be handed to an adapter function such as `zom_sql.compileRelation`.

### Projections

`select` narrows what a relation reads, like `SELECT id, name`. The query
stays typed on the full tuple, so `where` and `order`, before or after
`select`, may still use attributes that were not selected:

```zig
const names = try users.where(.age, .gt, 18).order(.age, .desc).select(.{ .id, .name }).toSlice(allocator);
defer allocator.free(names);
// @TypeOf(names[0]) has exactly `id` and `name`; `names[0].age` does not compile.
```

- Fields are listed as enum literals and come out in that order, with the
  types and defaults they have in the tuple. An empty list, an unknown field
  or a field listed twice is a compile error.
- **The primary key does not have to be selected.** rom doesn't require it,
  `SELECT name FROM users` is valid SQL, and zom never needs the key of a
  projected row: `update()` and `delete()` still work after `select`,
  because they go through the relation's query, not through rows read from
  it. `create` and `createMany` take whole tuples, so they are compile
  errors after `select`.
- `select` on a projected relation narrows it further, and may only name
  fields that were selected. Equal field lists give equal types, so
  `users.select(.{ .id, .name })` written twice is one type.
- A dataset with `supports.projection` reads the projection itself through
  `readProjected`. Any other dataset reads whole tuples, which zom maps down
  with `zom.Mapper` and frees, so `select` works with every adapter.

### Pagination

`page(n).perPage(k)` is page `n` of `k` rows, counting from 1, and
`paginate` reads it along with the total:

```zig
const p = try users.order(.id, .asc).page(2).perPage(20).paginate(allocator);
defer p.free(allocator);
// p.rows: rows 21 to 40 (fewer on the last page, none past it)
// p.total: every row of `users`, p.pages: ceil(total / 20)
// p.page == 2, p.per_page == 20
```

- The page's query is `offset((n - 1) * k).limit(k)`, replacing any
  `limit` and `offset` set before. `total` is `count()` on the same query
  without them, so filters count and paging doesn't. A page past the end
  has no rows and the same total.
- `page(0)` or `perPage(0)` is a compile error with a literal, and a panic
  with a runtime value: check user input first. When `(n - 1) * k` does
  not fit in `usize`, the read returns `error.ValueOutOfRange`.
- `paginate` is two dataset calls, a count then a read; run it in a
  transaction if a write in between would matter. `toSlice(allocator)`
  reads the rows alone, and `paged()` returns the relation with the
  offset and limit applied.
- Every relation has it, including projected and `.fallback` ones, and it
  needs `supports.offset` like `offset` does. It is a relation method,
  not a schema plugin: plugins hook into changesets, and paging only
  composes `limit`, `offset` and `count`.

### Query support: strict and fallback

A dataset says which query features it evaluates with `supports` and,
optionally, per attribute with `filterable` and `orderable` (see [the
adapter contract](adapters.md#the-adapter-contract)). A relation is `.strict` by default:
building a query the dataset can't run is a compile error, at the call that
needs the missing feature, naming the adapter, the relation, the call and the
feature:

```
zom: adapter 'limited' cannot evaluate `where(.name, .eq, ...)` on relation 'items': its dataset's `filterable` rejects `.eq` on 'name'; call `allowFallback()` on the relation to evaluate it in memory instead
```

`where`, `whereIn`, `whereNotIn` and `whereAny` / `whereNot` (every
condition inside them too) check filters, `order` and `reorder` check sort
keys, and `offset` and `page` check `supports.offset`. `select` and `limit` work on
every dataset.

`users.allowFallback()` returns the same relation in `.fallback` mode, where
those calls compile. Each read then splits the query: the top-level
conditions the dataset supports go to `read`, and zom filters the rows it
returns with the rest, through `Query.matches`. Once anything runs in
memory, the sort (when the dataset can't do it), `offset` and `limit` run in
memory too, after the filter, so pages are never short; `count` follows the
same rule.

**The cost is a hidden full scan.** A read whose filter or sort runs in
memory fetches every row that matches the supported part, with no limit,
however small the page. (When only `offset` is unsupported, the dataset reads
the first `offset + limit` rows instead.) So fallback is opt-in per relation,
which leaves a visible `allowFallback()` wherever a scan can happen, and
every such read calls the relation's scan hook with `zom.Scan{ adapter,
relation, rows_fetched, rows_returned }`. Set it once with the container's
`.on_scan`, or with `relation.onScan(hook)`, then log it in an app or assert
on it in a test. A read the dataset evaluates entirely is not reported.

```zig
const young = try users.allowFallback().where(.age, .lt, 30).limit(10).toSlice(allocator);
defer allocator.free(young);
```

## Value

```zig
const big: zom.Value = .{ .uint = std.math.maxInt(u64) };
std.debug.assert(big.order(.{ .int = -1 }).? == .gt);
std.debug.assert(big.order(.{ .string = "x" }) == null); // different kinds never compare
std.debug.assert(zom.query.toValue(@as(u64, 7)).eql(.{ .int = 7 }));
const id: zom.Value = .{ .uint128 = std.math.maxInt(u128) }; // a TigerBeetle id
std.debug.assert(id.order(big).? == .gt);
```

`zom.Value` is a `union(enum)`:

| Variant | Holds |
|---|---|
| `null` | A `null` optional attribute. |
| `boolean: bool` | `bool`. |
| `int: i64` | Every integer type up to 64 bits, except `u64`. |
| `uint: u64` | `u64` (and `usize` on 64-bit targets), and integer literals above `maxInt(i64)`. |
| `uint128: u128` | Unsigned integers of 65 to 128 bits (`u128` ids and amounts), and integer literals above `maxInt(u64)`. |
| `float: f64` | Float types. |
| `string: []const u8` | Strings, and enum values (by tag name). |

`a.order(b)` returns `?std.math.Order`: numbers compare across `int`,
`uint`, `uint128` and `float` (integers exactly, by widening both sides to
`i129`; against a float, through `f64`), strings compare bytewise, and
values of different kinds return `null`. `a.eql(b)` is `order == .eq`.
Signed integers wider than 64 bits, and any integer wider than 128, are a
compile error. `uint128` is stored at 8-byte alignment, so `Value` is 24
bytes on 64-bit targets, the same as without it.

## Errors

| Error | Returned by |
|---|---|
| `error.DuplicatePrimaryKey` | `create(...).commit()`, `createMany(...).commit()`, or an update that sets the primary key to one already in use (or sets it on more than one row). |
| `error.ValueOutOfRange` | `update().set(...).commit()` with a runtime value that does not fit the attribute, e.g. a `u32` holding 300 set on a `u8`. |
| `error.MoreThanOneTuple` | `one`. |
| `error.DatasetTypeMismatch` | `memory.Gateway.dataset` (and so `Relation.init`), when two different schema types share a dataset name. |
| `error.UnboundedWrite` | zom-sql's `compileUpdate` and `compileDelete`, for a query with no filters or join and `all` not set. |
| `error.ScanLimitExceeded` | zom-tigerbeetle's reads and counts, after fetching `Config.scan_max` records without finishing. |
| `error.EmptyUpdate` | zom-sql's `compileUpdate`, with no changes. |
| `error.UnsupportedFilter` | `update().commit()` and `delete()` on a `.fallback` relation with a filter its dataset can't evaluate. |
| `error.JoinUnavailable` | A join read on a `memory.Store` that no `memory.Gateway` handed out, so it has no other dataset to join. |
| `error.OutOfMemory` | Anything that takes or uses an allocator. |

`zom.adapter.Error` reserves the names every adapter uses for the same
condition (`DuplicatePrimaryKey`, `ValueOutOfRange`, `NotFound`, `ReadOnly`,
`ConnectionFailed`); its doc comments say when each one applies.
