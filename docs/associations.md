# Associations

A schema declares its associations once, in its options, so `combine`,
`join` and `associate` never take keys:

```zig
const UserSchema = zom.Schema(User, "users", .id, .{
    .associations = struct {
        pub const posts = zom.hasMany(PostSchema, .user_id);
    },
});
const PostSchema = zom.Schema(Post, "posts", .id, .{
    .associations = struct {
        pub const author = zom.belongsTo(UserSchema, .user_id);
    },
});

const posts = UserSchema.association(.posts); // or UserSchema.associations.posts
// posts.kind == .has_many, posts.target == PostSchema,
// posts.foreign_key == "user_id", posts.primary_key == "id"
```

`hasMany(Target, .fk)` means `Target`'s rows hold `fk`, pointing at this
schema's primary key. `belongsTo(Target, .fk)` means this schema's rows hold
`fk`, pointing at `Target`'s primary key. These are checked when the schema
is compiled, whether or not anything uses the association yet: the foreign key
must be a field of the right tuple, and its type must be the key's type or
that type made optional (`?u32` for a `u32` id). `S.association(.postz)` is a
compile error that lists the schema's associations.

## Views: schemas without a primary key

Some datasets have no single unique field: a row of TigerBeetle's balance
history is unique per account and timestamp, but one transfer's timestamp is
on both its accounts' rows. Declare such a schema with `null` as its key:

```zig
const BalanceSchema = zom.Schema(Balance, "balances", null, .{
    .associations = struct {
        pub const account = zom.belongsTo(AccountSchema, .account_id);
    },
});
```

`BalanceSchema.has_primary_key` is false, and whatever needs the key is a
compile error: `byPk`, `BalanceSchema.primary_key`, a `belongsTo` pointing at
the view, and a `hasMany` or custom association declared on it. A
`belongsTo` from the view and a `hasMany` into it work, since they use the
other schema's key. The memory store checks no keys for it (no
`error.DuplicatePrimaryKey`), and zom-pg's `verify` skips the primary-key
comparison.

**Why `struct { pub const ... }`.** Zig evaluates a function's arguments
before calling it, so with `.associations = .{ .posts = zom.hasMany(PostSchema, .user_id) }`
building `UserSchema` needs `PostSchema`, and if `PostSchema` names
`UserSchema` back, the compiler reports a dependency loop. A struct's
declarations are only evaluated when used, so the struct form lets both
schemas exist first and resolves the associations afterwards. The
anonymous-struct form `.{ .posts = ... }` is also accepted, for associations
that don't lead back to the schema declaring them.

## Combine

`users.combine(.posts, posts)` loads the users with their posts, ROM's
`users.combine(:posts)`. The second argument is the relation to read the
posts from: any relation over the association's target schema, so it can
carry its own filters and order. With a container, pass its relation:
`app.relations.users.combine(.posts, app.relations.posts)`.

```zig
const Author = struct { id: u32, name: []const u8, posts: []const Post };

var result = try users.where(.age, .gt, 18).order(.id, .asc)
    .combine(.posts, posts.where(.published, .eq, true))
    .mapTo(Author, allocator);
defer result.deinit(); // frees every author, post and string
for (result.items) |author| std.debug.print("{s}: {d} posts\n", .{ author.name, author.posts.len });
```

Nothing is read until `mapTo` (or `mapWith(M, allocator)`, for a mapper
with renames). Then:

1. The users are read once, with their filters, order and limit.
2. Their distinct keys are collected, and the posts are read with
   `whereIn(.user_id, keys)`: one query, or ⌈keys / `Query.max_in`⌉ when
   there are more than 64 keys. Each post keeps its relation's order within
   its user.
3. The posts are grouped by key with a hash map, in O(users + posts), and
   each `Author.posts` gets its own: an empty slice when there are none.
   Posts whose user was filtered out are dropped.

`belongsTo` works the other way: `posts.combine(.author, users).mapTo(Byline, allocator)`
fills `Byline.author: ?User` (or any struct the user maps to), which is null
when the foreign key is null or its user was not read.

The entity needs a field named after the association: `[]const X` for
`hasMany`, `?X` for `belongsTo`, where `X` is the target's tuple or any
struct `zom.Mapper` can map it to. It needs no default. A missing field, a
field of the wrong shape, a target relation over the wrong schema and a key
dropped by `select` are compile errors.

Combine groups by the primary key's type (without `?`), with a hash map.
Supported key types are integers (signed up to `i64`, unsigned up to
`u128`, so TigerBeetle ids work), enums, `bool` and strings (`[]const u8`).
Any other key type is a `zom.combine` compile error naming it: floats,
because they compare badly as keys, and structs, arrays or other slices,
because composite keys aren't supported yet.

`mapWith(M, allocator)` takes a `zom.Mapper`, which combine rebuilds to
leave the association field alone, so it needs no default there either. It
also takes a mapper written by hand: a struct with `Input` (the source
relation's `Output`), `Output` and `pub fn call(Input) Output`. Combine
can't rebuild that one, so it is used as is: its `call` must set the
association field to something, such as `&.{}` or `null`, and combine then
overwrites it. A struct without that `call` is a compile error.

A `limit` or `offset` on the target relation pages each user's posts, not
the post query: `users.combine(.posts, posts.order(.id, .desc).limit(3))`
gives every user their latest three posts. A limit on the query itself
would apply to each batch of `max_in` keys and mean nothing. For a
`belongsTo`, the parent is the first row of its page, so `offset(1)` leaves
it null.

Where the page is applied depends on the target's dataset. One with
`supports.per_group_limit` pages each user's posts itself, so only the
posts kept are read: zom-pg (through zom-sql) numbers them with
`ROW_NUMBER() OVER (PARTITION BY "user_id" ORDER BY ...)` and sends back
those on the page, and zom-tigerbeetle asks the cluster for each account's
page alone. Any other dataset, or a `.fallback` target whose read filters,
sorts or skips in memory, gets the query without the page: zom reads every
matching post and keeps each user's first three in the relation's order.
The result is the same either way.

The result is a tree of allocations, so `mapTo` returns a
`zom.CombineResult(Author)`: `items`, plus an arena owning every slice and
string in it, including the strings of a caller-owned adapter like zom-pg.
One `deinit()` frees it all.

## Custom associations and `loadAssociation`

Steps 2 and 3 assume each child row holds one foreign key. Some don't: a
TigerBeetle transfer belongs to an account as its `debit_account_id` *or*
its `credit_account_id`. `zom.customAssociation` declares such an
association by what the target's dataset calls it, and whether each source
row gets a slice (`.many`) or an optional (`.one`):

```zig
pub const Account = zom.Schema(tb.Account, "accounts", .id, .{
    .associations = struct {
        pub const transfers = zom.customAssociation(Transfer, .account_transfers, .many);
    },
});

var history = try accounts.byPk(id).combine(.transfers, transfers).mapTo(AccountWithTransfers, allocator);
```

The target's dataset then loads the rows itself, with an optional
declaration that `combine` looks for with `@hasDecl` at compile time:

```zig
pub fn loadAssociation(
    self: *Self,
    comptime a: zom.Association,
    keys: []const a.Key(),     // the source rows' distinct keys
    query: zom.Query(S.Tuple), // the combined relation's whole query
    allocator: std.mem.Allocator, // the result's arena
) ![]const []const S.Tuple    // one slice per key, in the order of `keys`
```

When a dataset declares it, *every* combine into that dataset calls it once
instead of steps 2 and 3, for `hasMany` and `belongsTo` too, so a backend
can pick a better request than an `in` query (zom-tigerbeetle uses
`get_account_transfers`). It must apply all of `query`, including filters a
`.fallback` relation would have run in memory, and order each slice by it;
a row may be in several slices. Its `limit` and `offset` are taken off and
applied to each slice afterwards, unless the dataset declares
`supports.per_group_limit`: then it gets them and pages each key's slice
itself. Everything it returns lives in the arena,
so it frees nothing. A custom association combined into a dataset without
`loadAssociation` is a compile error, and so are `join` and `associate` on
one, which need a foreign key.

## Join

`users.join(.posts)` keeps the users that have at least one post, ROM's
`users.join(:posts)`. Where `combine` loads the posts alongside the users,
a join filters the users by their posts in the dataset and reads only the
users' own columns, so it returns a relation of the same type: `where`,
`order`, `limit`, `offset`, `count`, `select` and `combine` all still apply,
before or after it. `whereJoined` filters on the joined rows, typed and
checked like `where` on the posts' tuple:

```zig
// The users with at least one published post, each once.
const authors = try users.join(.posts)
    .whereJoined(.posts, .published, .eq, true)
    .order(.name, .asc)
    .toSlice(allocator);
defer users.free(allocator, authors);
```

Several `whereJoined` filters are AND-ed and must all hold for the same
post. A user with several matching posts still comes back once. `belongsTo`
joins the other way: `posts.join(.author).whereJoined(.author, .role, .eq,
.admin)` is the posts written by admins, and a post whose foreign key is
null has no author to join.

`whereJoinedAny` and `whereJoinedNot` take the same conditions as
`whereAny` and `whereNot`, over the joined tuple, and need `supports.or` on
the joined dataset. `whereJoinedIn` and `whereJoinedNotIn` take a runtime
slice and borrow it, like `whereIn`:

```zig
// The users with a post that is published or has 10+ likes.
const busy = users.join(.posts)
    .whereJoinedAny(.posts, .{ .{ .published, .eq, true }, .{ .likes, .gte, 10 } });
// The users with one of these posts.
const picked = users.join(.posts).whereJoinedIn(.posts, .id, post_ids);
```

Everything on a join is AND-ed for the same joined row, groups included.
So `whereJoinedNot(.posts, .{ .published, .eq, true })` is the users with
a post that is not published, not the users with no published post.

A join needs `supports.join`. Without it, `join` and `whereJoined` are
compile errors on a `.fallback` relation too, since a join reads another
dataset and can't run in memory on this one's rows. zom-pg and the memory
gateway support it; csv and yaml do not. On zom-sql it compiles to a
correlated semi-join

```sql
SELECT "users"."id", "users"."name", ... FROM "users"
WHERE EXISTS (SELECT 1 FROM "posts"
  WHERE "posts"."user_id" = "users"."id" AND "posts"."published" = $1)
ORDER BY "users"."name" ASC
```

with every column qualified by its table. Each user comes back once with
no `DISTINCT`, so columns without equality (`json`) and projections work
as on an unjoined query. The memory gateway runs a hash
semi-join: the matching posts' keys go into a set, and a user is kept when
its key is in it, in O(users + posts).

Joins add up, to `Query.max_joins` (3) per query:
`users.join(.posts).join(.comments)` is the users with at least one post
and at least one comment, each joined association matched (and narrowed by
its own `whereJoined`) on its own rows. It is not the users with a post
that has a comment, which would be a join through `posts`. On zom-sql each
join is one more `AND EXISTS (...)`, in the order joined, and in memory one
more key set a row's key must be in. Joining an association the relation
already joins changes nothing, filters and all, so "a published post and an
unpublished one" can't be two joins on `.posts`. A fourth join panics, as
does `whereJoined` without its `join`. `update` and `delete` on a joined
relation affect each matching source row once. The SQL compiler uses the
same `EXISTS` subqueries; memory snapshots the matching rows before
changing them.

## Associated creates

`posts.associate(.author, user)` is ROM's `changeset.associate(user)`, with
the parent first: its `create` takes the post without `user_id`, and the
key comes from `user`:

```zig
const author = (try users.byPk(1).one(allocator)).?;
_ = try posts.associate(.author, author)
    .create(.{ .id = 12, .title = "Changesets" })
    .commit();
```

The struct `create` takes is the tuple without the association's foreign
key, with the same types and defaults otherwise, so the literal is typed
as usual and the key can't be forgotten or given twice. Chain `associate`
for several `belongsTo` associations (a comment's post and author). For a
batch, `posts.associate(.author, author).createMany(&rows)` takes rows of
that struct, `@TypeOf(scoped).Input`, and commits with
`commitAlloc(allocator)`, because it builds the stored tuples in a copy.

**Why the parent comes first.** ROM's `create(data)` leaves out `user_id`,
but a Zig struct has no unset fields, so a post literal without `user_id`
doesn't compile. Giving the key a default in the tuple would let a post
silently belong to user 0. Making `create` accept a partial struct would
mean an `anytype` parameter, and Zig doesn't coerce an anonymous
struct to a named one, so every `create` literal would lose its result
type (`.id = @intCast(n)` would stop compiling). So `create` keeps taking a
whole tuple. ROM's order still works if you give the key a value first:
`posts.create(.{ .id = 13, .user_id = undefined, ... }).associate(.author, author)`,
and `posts.createMany(&tuples).associate(.author, author).commitAlloc(allocator)`
for a batch. Nothing catches a forgotten `associate` in that form.

The parent must be the target's tuple, or a `select` of it that kept the
key (any struct whose fields are all fields of the target's tuple, with
the same types). Any other type, such as another schema's tuple, is a
compile error, and so is a `hasMany` association, whose foreign key is in
the other schema's rows: `users.associate(.posts, post)` points you at
`posts.associate(.author, ...)`.

## Nesting

The relation passed to `combine` can be a combine itself, so a combine
loads more than one level: users with their posts, each post with its
comments.

```zig
const Comment = struct { id: u32, body: []const u8 };
const PostWithComments = struct { id: u32, title: []const u8, comments: []const Comment };
const Author = struct { id: u32, name: []const u8, posts: []const PostWithComments };

var result = try users.order(.id, .asc)
    .combine(.posts, posts.order(.id, .asc).combine(.comments, comments.order(.id, .asc)))
    .mapTo(Author, allocator);
defer result.deinit(); // frees every level
```

The element type of `Author.posts`, here `PostWithComments`, drives the
inner level: each post row is mapped to it by attribute name, and its
`comments` field is filled the way `Author.posts` is. The field-shape
checks (`[]const X` for `hasMany`, `?X` for `belongsTo`) and the
per-parent paging apply at every level, and levels can be
nested deeper the same way. `hasMany` and `belongsTo` mix freely:
`posts.combine(.author, users)` inside a combine fills each post's `?User`.

Each level runs once, on every row the level above it read:

1. The users are read.
2. The posts are read with `whereIn(.user_id, ...)`, ⌈users / `max_in`⌉
   queries.
3. The comments are read with `whereIn(.post_id, ...)`, ⌈posts / `max_in`⌉
   queries, over all posts at once, not per batch of the level above.

So a combine makes 1 + Σ ⌈keys / `max_in`⌉ queries across its levels, and a
level whose parents have no keys makes none. A level into a dataset with
`loadAssociation` loads through it, and the rows it returns get their own
association filled the same way. One `result.deinit()` frees the whole
tree. The inner levels map by attribute name; `mapWith` applies to the
outermost rows only.

The `whereIn` takes one of the target query's `max_filters` filters (and
`max_nodes` nodes), so a target relation that already uses them all is
`error.CombineTargetFull`, at any level, even when there are no keys. A
target dataset with `loadAssociation` adds no filter and has no such limit.
