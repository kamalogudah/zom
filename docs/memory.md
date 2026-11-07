# Memory rules

- `toSlice`, `mapTo`, `mapWith` and `Mapper.many` return slices the caller
  owns. zom-sql's `compile*` functions return a `Compiled` that the caller
  frees with `compiled.deinit(allocator)`.
- Every adapter copies string attributes on insert and update, so input
  buffers can be reused straight away.
- Who owns the strings you read back depends on the adapter's
  `zom.StringOwnership`. With `.dataset` (memory, CSV, YAML) they point into
  the dataset and stay valid as long as the gateway lives. With `.caller`
  (zom-pg) they are allocated with the allocator you passed to the read (or
  to `commitAlloc`) and are yours. Code that should run on any adapter frees
  with the relation:

  ```zig
  const rows = try users.toSlice(allocator);
  defer users.free(allocator, rows); // allocator.free(rows) on memory
  if (try users.byPk(1).one(allocator)) |u| {
      defer users.freeOne(allocator, u); // a no-op on memory
  }
  const stored = try users.create(tuple).commitAlloc(allocator);
  defer users.freeOne(allocator, stored);
  ```

  zom frees the strings it drops along the way (rows filtered out in memory
  by a `.fallback` read, attributes `select` leaves out, the extra row
  `one` reads). After `mapTo` / `mapWith`, the strings the mapper copied
  belong to the entities (`zom.strings.freeAll(E, allocator, entities)`
  frees them); the rest are freed. An arena per request avoids all of this.
- `createMany` does not copy the slice you pass; keep it alive until
  `commit`. The tuples' strings are copied on commit, as with `create`.
- A relation does not copy the values you filter on. A string passed to
  `where`, and the slice passed to `whereIn` / `whereNotIn`, must stay alive
  and unchanged until the relation (and every relation chained from it) is
  last used. A tuple given to `where(.x, .in, .{ ... })` has no such limit:
  its values are comptime-known and stored statically.
- The gateway must outlive every relation made from it, and
  `memory.Gateway.deinit` frees all of its datasets at once.
- `relation.combine(...).mapTo` returns a `zom.CombineResult` whose
  `deinit()` frees every slice and string in it. For the deprecated
  `combineMany`, use an arena: it allocates one child slice per parent.
