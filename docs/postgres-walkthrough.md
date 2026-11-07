# Walkthrough: a repository and transactions on Postgres

A line-by-line tour of [examples/pg_repo](../examples/pg_repo/src/main.zig). How to start Postgres and run it is in [examples/README.md](../examples/README.md#pg_repo-a-repository-and-transactions-on-postgres).

## A repository and a transaction, on Postgres

[examples/pg_repo](../examples/pg_repo/src/main.zig) is a small application:
a container with one [zom-pg](../adapters/pg/README.md) gateway, a repository with a custom
view, and a sign-up that writes a user and their first posts in one
transaction, so a failure part way through leaves neither. Start Postgres,
create the tables, and run it:

```sh
docker run --rm -d --name zom-pg -p 5432:5432 -e POSTGRES_PASSWORD=postgres postgres:17
export DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres

cd examples/pg_repo
psql "$DATABASE_URL" -f schema.sql   # or: docker exec -i zom-pg psql -U postgres < schema.sql
zig build run                        # or: zig build run -- postgres://...
```

```text
committed: Achieng, with 2 posts
rolled back: DuplicatePrimaryKey (posts_pkey)
  users named Baraka: 0, posts by user 2: 0
active users: 1 of 2
Achieng <achieng@example.com>
  - Relations are values
  - Transactions roll back
```

The app depends on zom with `.pg = true`, which builds the `zom_pg` module
(see [its build.zig](../examples/pg_repo/build.zig)). The schemas and the
container are the same as with any other gateway; only the gateway type
says Postgres:

```zig
const App = zom.Container(.{
    .gateways = .{ .db = zom_pg.Gateway },
    .relations = .{
        .users = .{ UserSchema, .db },
        .posts = .{ PostSchema, .db },
    },
});

/// The custom view: rom's `def active = where(deleted_at: nil)`.
const Users = struct {
    rel: @FieldType(App.Relations, "users"),

    pub fn active(self: Users) @TypeOf(self.rel) {
        return self.rel.where(.deleted_at, .eq, null);
    }
};

const UserRepo = zom.Repository(App, .{ .root = .users, .relations = .{ .users = Users, .posts = .plain } });
```

`main` reads the URL from its first argument or from `DATABASE_URL`, opens
the container, and checks both tables against the structs with zom-pg's
`verify`, so a missing `schema.sql` is one clear error at startup rather
than a failed query later:

```zig
var app: App = undefined;
try app.init(init.gpa, .{ .db = .{ .io = io, .url = url, .pool_size = 2 } });
defer app.deinit();

try verify(&app.gateways.db, UserSchema, arena);
try verify(&app.gateways.db, PostSchema, arena);
var repo = UserRepo.init(&app);
```

The sign-up runs in `app.transaction(.db, ctx, f)`. Zig has no closures, so
what `f` needs comes in as `ctx`, and `f` gets `tx`, the container's
relations rebound to the transaction's connection.
`UserRepo.fromRelations(tx)` builds the same repository over them. `f`
commits by returning and rolls back by returning an error:

```zig
const SignUp = struct {
    allocator: std.mem.Allocator,
    user: User,
    posts: []const Post,
};

fn signUp(s: SignUp, tx: App.Relations) !usize {
    const repo = UserRepo.fromRelations(tx);
    // zom-pg's strings belong to the caller, so a create that returns the
    // stored row takes an allocator (`commit()` would be a compile error).
    _ = try repo.create(s.user).commitAlloc(s.allocator);
    return repo.relations.posts.createMany(s.posts).commit();
}
```

The second sign-up fails on purpose: its post reuses id 10, which is
Achieng's. The user row is already written by then, and the rollback takes
it out again. The error comes back from `transaction` unchanged, and
`lastError()` has the Postgres details:

```zig
if (app.transaction(.db, SignUp{
    .allocator = arena,
    .user = .{ .id = 2, .name = "Baraka", .email = "baraka@example.com" },
    .posts = &.{.{ .id = 10, .user_id = 2, .title = "First!" }},
}, signUp)) |_| {
    return error.ExpectedRollback;
} else |err| switch (err) {
    error.DuplicatePrimaryKey => {
        const constraint = if (zom_pg.Gateway.lastError()) |e| e.constraint orelse "?" else "?";
        try out.print("rolled back: {t} ({s})\n", .{ err, constraint });
    },
    else => return err,
}
```

Then reads go through the view and the root shortcuts, and `combine` loads
the active users' posts with one `IN (...)` query:

```zig
try out.print("active users: {d} of {d}\n", .{ try repo.root().active().count(), try repo.all().count() });
const authors = try repo.root().active().order(.id, .asc)
    .combine(.posts, repo.relations.posts.order(.id, .asc))
    .mapTo(Author, arena);
```

Every row is read into `init.arena`, which `main` frees once on return:
zom-pg copies each string it returns into the allocator you pass (see
[Memory rules](memory.md#memory-rules)), and an arena is the simplest owner for a
short program. The example empties both tables when it starts, so every run
prints the same thing.

## Debugging: error return traces

When `main` returns an error, a `debug` or `safe` build prints the error
and its **error return trace**: every `try` the error passed through on its
way out, innermost first. Run the example before applying `schema.sql`:

```text
$ zig build run
error: table 'users' doesn't match the schema; did you run `psql "$DATABASE_URL" -f schema.sql`?
users: no such table
error: SchemaMismatch
adapters/pg/src/verify.zig:116:5: 0x1230d63 in verify__anon_37199 (root.zig)
    return error.SchemaMismatch;
    ^
adapters/pg/src/gateway.zig:158:9: 0x1230f59 in verify__anon_37187 (root.zig)
        return verify_mod.verify(self, S, diagnostics);
        ^
examples/pg_repo/src/main.zig:159:13: 0x123111f in verify__anon_37156 (main.zig)
            return err;
            ^
examples/pg_repo/src/main.zig:89:5: 0x124934b in main (main.zig)
    try verify(&app.gateways.db, UserSchema, arena);
    ^
```

This is not a stack trace from where the program stopped: it records where
the error was returned and each place that passed it on, so it points into
zom-pg and pg.zig as well as your code. A wrong password or a stopped server
gives `ConnectionFailed`, with a trace down to the socket `connect` in
pg.zig. Some tips:

- The trace is only kept in `debug` and `safe` builds. `zig build run
  -Doptimize=fast` prints just `error: SchemaMismatch`.
- `catch |err| switch (err)` is where you decide which errors are expected
  (here `error.DuplicatePrimaryKey`) and pass the others on with
  `else => return err`, which keeps the trace going.
- zom-pg logs each Postgres error, with its SQLSTATE and message, at debug
  level under the `.zom_pg` scope. The example turns that scope down to
  `.info` in `std_options`, since it causes a duplicate key on purpose; set
  it back to `.debug` to see every one.
- `zom_pg.Gateway.lastError()` returns the last Postgres error on the
  current thread (code, message, detail, constraint), after the call that
  failed.
