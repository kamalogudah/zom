//! The TigerBeetle gateway: one `tb_client` (the C client, linked as a
//! static library) and a dataset for each of the two fixed schemas,
//! `zom_tigerbeetle.Account` and `zom_tigerbeetle.Transfer`.
//!
//! Writes are `insert` and `insertMany`, on `create_accounts` /
//! `create_transfers`. TigerBeetle records are immutable, so the datasets
//! have no `update` and no `delete`: `relation.update()` and
//! `relation.delete()` don't compile.
//!
//! Reads are `lookup_*` for `byPk` and `where(.id, .in, ...)`, and
//! `query_*` for equality on `user_data_128/64/32`, `ledger` and `code`
//! and ranges of `timestamp`, ordered by `timestamp` either way and paged
//! through with a timestamp cursor. Other filters and orders are a compile
//! error on a strict relation, and run in memory on a `.fallback` one; so
//! does `offset`, which TigerBeetle has no way to do. See read.zig for the
//! whole mapping. TigerBeetle can't count, so `count` reads the matching
//! rows and counts them: at most `Config.scan_max`, like any read.
//!
//! A third, read-only dataset, `zom_tigerbeetle.AccountBalance`, reads an
//! account's balance history through `get_account_balances` (`BalanceDataset`).
//!
//! `combine` into accounts or transfers goes through the datasets'
//! `loadAssociation` (see zom's combine.zig), which picks the request for
//! the association at compile time: `get_account_transfers` for
//! `Account.transfers` (a custom association: debit or credit account) and
//! for a `hasMany` on `debit_account_id` / `credit_account_id`,
//! `lookup_*` for a `belongsTo`, and one `query_*` per key for a `hasMany`
//! on an indexed field (`user_data_*`, `ledger`, `code`).
//!
//! ## Threads and blocking
//!
//! The client runs its own thread, which does all the network I/O.
//! `tb_client_submit` queues a request from any thread and returns at once;
//! the client's thread calls `onCompletion` when the reply arrives. zom's
//! calls are synchronous, so `submit` blocks the calling task on a
//! `std.Io.Event` until then, which the completion sets. The wait can't be
//! cancelled: the request lives on the caller's stack, and the client
//! writes into it until it completes. With a threaded `std.Io` only the
//! calling thread waits; with an evented one, other tasks run meanwhile.
//!
//! One gateway can be used from several threads at once: each call has its
//! own request, and `tb_client_submit` is thread-safe. The client batches
//! requests that are queued together, so many threads each inserting one
//! row still reach the cluster as few requests.

const std = @import("std");
const zom = @import("zom");
const tb = @import("tb.zig");
const results = @import("results.zig");
const reads = @import("read.zig");
const schemas = @import("schemas.zig");
const chains = @import("linked.zig");
const c = tb.c;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zom_tigerbeetle);

pub const Gateway = struct {
    pub const adapter_name = "tigerbeetle";

    /// Added to `container.transaction`'s compile error: TigerBeetle's
    /// atomicity is a linked chain of events in one request.
    pub const transaction_hint = "TigerBeetle's all-or-nothing writes are linked event chains: " ++
        "`relation.linked().add(a).add(b).commit()` (see zom_tigerbeetle's linked.zig)";

    pub const Config = struct {
        /// The client's replies are waited for through `std.Io`.
        io: std.Io,
        cluster_id: u128,
        /// The replicas, comma-separated: `"3000"`, `"127.0.0.1:3000"`, or
        /// `"10.0.0.1:3000,10.0.0.2:3000,10.0.0.3:3000"`.
        addresses: []const u8,
        /// The most events `insertMany` puts in one request. The cluster
        /// sets the real limit, which the client knows but doesn't expose:
        /// 8189 by default, 253 for a `--development` cluster. When a
        /// request is too big, the client refuses it before sending
        /// anything, and the gateway retries smaller until it finds the
        /// cluster's limit, which it then keeps (see `batchLimit`). Setting
        /// this to the cluster's limit skips that search.
        batch_max: u32 = tb.batch_max,
        /// The most records one read or count fetches from the cluster
        /// before it gives up with `error.ScanLimitExceeded`. Every read
        /// that isn't a lookup pages through `query_*` replies of up to
        /// 8189 records (`read.query_max`), so this is the bound on that
        /// loop. A read with a limit, filtered on what TigerBeetle
        /// evaluates, fetches no more than its limit; one without, or a
        /// `count`, fetches every match. Rows filtered out in memory
        /// count too: `user_data_64 = 0`, which `QueryFilter` can't say,
        /// fetches every row to keep the ones with 0.
        scan_max: u64 = 1 << 20,
    };

    /// What every zom-tigerbeetle call can fail with. The first is one of
    /// zom's shared names (`zom.Error`). Inserts add the result codes'
    /// errors: see `Dataset(S).InsertError`.
    pub const Error = error{
        /// The client was evicted, shut down, or the cluster runs a release
        /// it can't talk to (`TB_PACKET_CLIENT_*`), or `init` could not set
        /// up networking.
        ConnectionFailed,
        /// `addresses` doesn't parse, or names more replicas than the
        /// client allows.
        InvalidAddress,
        /// The OS refused a thread, file descriptor or the like.
        SystemResources,
        /// `insertMany` was given a linked chain (events with
        /// `flags.linked`, and the one closing it) longer than the
        /// cluster's batch limit. A chain must go in one request, so it
        /// wasn't sent. Checked against `batch_max` before anything is
        /// sent, and against the cluster's limit once it is known.
        LinkedChainTooLong,
        /// The client rejected a request zom built (`INVALID_OPERATION`,
        /// `INVALID_DATA_SIZE`, `TOO_MUCH_DATA` for a single event), a reply
        /// had the wrong size, or `tb_client_init` failed for no stated
        /// reason. A bug in zom-tigerbeetle.
        Unexpected,
        /// A read or count fetched `Config.scan_max` records and wasn't
        /// done. Narrow it (a limit, or filters TigerBeetle evaluates), or
        /// raise `scan_max`.
        ScanLimitExceeded,
        OutOfMemory,
        /// `std.Io` cancelled the wait for a reply.
        Canceled,
    };

    allocator: Allocator,
    /// On the heap, because `tb_client_t` and the datasets must not move
    /// while the client runs, and `init` returns the gateway by value.
    shared: *Shared,

    const Shared = struct {
        client: c.tb_client_t,
        io: std.Io,
        allocator: Allocator,
        batch_max: u32,
        scan_max: u64,
        /// What is known of the cluster's batch limit: the largest batch it
        /// took, and the smallest the client refused. Several threads may
        /// update them at once; a race only costs a retry.
        fits: std.atomic.Value(u32) = .init(0),
        too_big: std.atomic.Value(u32) = .init(std.math.maxInt(u32)),
        /// Requests sent to the cluster, for `requestCount`.
        requests: std.atomic.Value(u64) = .init(0),
        accounts: Dataset(schemas.Account),
        transfers: Dataset(schemas.Transfer),
        balances: Dataset(schemas.AccountBalance),

        /// See `Gateway.batchLimit`. Never 0: a single event is never
        /// recorded as too big (`createBatch`), so `too_big >= 2`.
        fn batchLimit(self: *const Shared) u32 {
            const fits = self.fits.load(.monotonic);
            const too_big = self.too_big.load(.monotonic);
            if (too_big > self.batch_max) return self.batch_max;
            if (fits + 1 >= too_big) return fits;
            return fits + (too_big - fits) / 2;
        }

        /// Sends one request and blocks until its reply. `events` is the
        /// request body (a slice of `tb.Account`s, ids, filters...), and
        /// the reply is copied into `reply`, which must be big enough for
        /// any reply to `events` (the caller knows the bound per
        /// operation). Returns the reply's length in bytes.
        ///
        /// `error.TooMuchData` means the client refused the request as
        /// bigger than the cluster takes, without sending it.
        fn submit(self: *Shared, operation: c.TB_OPERATION, events: []const u8, reply: []u8) (Error || error{TooMuchData})!usize {
            var request: Request = .{ .reply = reply };
            var packet = std.mem.zeroes(c.tb_packet_t);
            packet.user_data = &request;
            packet.data = @constCast(events.ptr);
            packet.data_size = std.math.cast(u32, events.len) orelse return error.Unexpected;
            packet.operation = @intCast(operation);

            // Only an uninitialized or closed client is refused, and a
            // gateway's client is neither until `deinit`.
            const status = c.tb_client_submit(&self.client, &packet);
            std.debug.assert(status == c.TB_CLIENT_OK);
            // `packet` and `request` are on this stack, so the reply must be
            // waited for even when the caller's task is cancelled.
            request.done.waitUncancelable(self.io);

            if (request.status == c.TB_PACKET_TOO_MUCH_DATA) return error.TooMuchData;
            _ = self.requests.fetchAdd(1, .monotonic);
            return switch (request.status) {
                c.TB_PACKET_OK => request.len,
                c.TB_PACKET_CLIENT_EVICTED,
                c.TB_PACKET_CLIENT_RELEASE_TOO_LOW,
                c.TB_PACKET_CLIENT_RELEASE_TOO_HIGH,
                c.TB_PACKET_CLIENT_SHUTDOWN,
                => error.ConnectionFailed,
                else => {
                    log.debug("packet for operation {d} failed with status {d}", .{ operation, request.status });
                    return error.Unexpected;
                },
            };
        }

        /// One read request (`lookup_*`, `query_*`, `get_account_*`) whose
        /// reply is records of type `R`, at most `reply.len` of them.
        fn submitRecords(self: *Shared, comptime R: type, op: c.TB_OPERATION, events: []const u8, reply: []R) Error![]R {
            const len = self.submit(op, events, std.mem.sliceAsBytes(reply)) catch |err| switch (err) {
                // One filter, or at most 64 ids, is far below any cluster's
                // smallest request (see `reads.lookup_max`).
                error.TooMuchData => return error.Unexpected,
                else => |e| return e,
            };
            if (len % @sizeOf(R) != 0) {
                log.debug("a read reply of {d} bytes isn't whole records", .{len});
                return error.Unexpected;
            }
            return reply[0 .. len / @sizeOf(R)];
        }

        /// `op` (`query_*` or `get_account_*`) from `base`, its filter, a
        /// page at a time: each page starts past the last timestamp of the
        /// one before (`reads.advance`). Calls `sink.take(row)` for every
        /// row, in the order they come, which returns whether it kept it,
        /// until `want` are kept (null: all of them). At most `scan_max`
        /// rows are fetched, or `error.ScanLimitExceeded`.
        fn scanPages(self: *Shared, comptime R: type, op: c.TB_OPERATION, base: anytype, want: ?usize, sink: anytype) Error!void {
            if (want == 0) return;
            const page_max: u32 = @intCast(@min(want orelse reads.query_max, reads.query_max, self.scan_max));
            const page = try self.allocator.alloc(R, page_max);
            defer self.allocator.free(page);

            var filter = base;
            var kept: usize = 0;
            var fetched: u64 = 0;
            // Once a row is dropped, pages may need more rows than the
            // matches still missing.
            var dropped = false;
            // Every page but the last is full, so `fetched` grows by at
            // least one per page, and `scan_max` bounds the loop. A page is
            // never bigger than what is left of `scan_max`, so a read that
            // stops there fetched exactly `scan_max` rows.
            while (fetched < self.scan_max) {
                const missing: u64 = if (want) |w| (if (dropped) page_max else w - kept) else page_max;
                const asked: u32 = @intCast(@min(page_max, missing, self.scan_max - fetched));
                std.debug.assert(asked > 0);
                filter.limit = asked;
                const rows = try self.submitRecords(R, op, std.mem.asBytes(&filter), page[0..asked]);
                fetched += rows.len;
                for (rows) |row| {
                    if (!try sink.take(row)) {
                        dropped = true;
                        continue;
                    }
                    kept += 1;
                    if (kept == want) return;
                }
                // A short page is the last (see `reads.query_max`).
                if (rows.len < asked) return;
                if (!reads.advance(&filter, rows[rows.len - 1].timestamp)) return;
            }
            return error.ScanLimitExceeded;
        }
    };

    /// Starts the client. It connects in the background: an unreachable
    /// cluster shows up on the first request, not here.
    pub fn init(allocator: Allocator, config: Config) Error!Gateway {
        std.debug.assert(config.batch_max > 0);
        std.debug.assert(config.scan_max > 0);
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{
            .client = undefined,
            .io = config.io,
            .allocator = allocator,
            .batch_max = config.batch_max,
            .scan_max = config.scan_max,
            .accounts = .{ .shared = shared },
            .transfers = .{ .shared = shared },
            .balances = .{ .shared = shared },
        };

        const cluster_id: [16]u8 = @bitCast(std.mem.nativeToLittle(u128, config.cluster_id));
        const len = std.math.cast(u32, config.addresses.len) orelse return error.InvalidAddress;
        const status = c.tb_client_init(&shared.client, &cluster_id, config.addresses.ptr, len, @intFromPtr(shared), onCompletion);
        if (status != c.TB_INIT_SUCCESS) {
            log.debug("tb_client_init failed with status {d}", .{status});
            return switch (status) {
                c.TB_INIT_OUT_OF_MEMORY => error.OutOfMemory,
                c.TB_INIT_ADDRESS_INVALID, c.TB_INIT_ADDRESS_LIMIT_EXCEEDED => error.InvalidAddress,
                c.TB_INIT_SYSTEM_RESOURCES => error.SystemResources,
                c.TB_INIT_NETWORK_SUBSYSTEM => error.ConnectionFailed,
                else => error.Unexpected,
            };
        }
        return .{ .allocator = allocator, .shared = shared };
    }

    /// Stops the client. Requests still in flight complete with
    /// `error.ConnectionFailed` first.
    pub fn deinit(self: *Gateway) void {
        const status = c.tb_client_deinit(&self.shared.client);
        std.debug.assert(status == c.TB_CLIENT_OK);
        self.allocator.destroy(self.shared);
        self.* = undefined;
    }

    /// One of zom-tigerbeetle's datasets. `S` must be a `zom.Schema` of
    /// `tb.Account` or `tb.Transfer` keyed by `.id`, such as
    /// `zom_tigerbeetle.Account`, or of `tb.AccountBalance` keyed by
    /// `.timestamp` (the read-only balance view); the dataset name is not
    /// used, since TigerBeetle's are fixed. Every schema over a tuple shares
    /// that tuple's one dataset, so this is the fixed schema's dataset type.
    pub fn Dataset(comptime S: type) type {
        comptime checkSchema(S);
        if (S.Tuple == tb.Account) return TbDataset(schemas.Account);
        if (S.Tuple == tb.Transfer) return TbDataset(schemas.Transfer);
        return BalanceDataset(schemas.AccountBalance);
    }

    /// The dataset for `S`. The pointer stays valid until `deinit`.
    pub fn dataset(self: *Gateway, comptime S: type) error{}!*Dataset(S) {
        if (comptime S.Tuple == tb.Account) return &self.shared.accounts;
        if (comptime S.Tuple == tb.Transfer) return &self.shared.transfers;
        return &self.shared.balances;
    }

    /// How many requests this gateway has sent to the cluster, e.g. to see
    /// how `insertMany` split a batch. Requests the client refused as too
    /// big were not sent, so they don't count.
    pub fn requestCount(self: *const Gateway) u64 {
        return self.shared.requests.load(.monotonic);
    }

    /// The most events `insertMany` will try in one request now:
    /// `batch_max` until a request is refused as too big, then a size
    /// between the largest batch the cluster took and the smallest it
    /// refused, which ends at the cluster's limit.
    pub fn batchLimit(self: *const Gateway) u32 {
        return self.shared.batchLimit();
    }

    /// One `submit` in flight, pointed to by its packet's `user_data`.
    const Request = struct {
        reply: []u8,
        len: usize = 0,
        status: c.TB_PACKET_STATUS = c.TB_PACKET_OK,
        done: std.Io.Event = .unset,
    };

    /// Runs on the client's thread. `ctx` is the `*Shared` that `init`
    /// passed as the completion context. `result` is only valid during the
    /// call, so it is copied out before the waiting `submit` is woken.
    fn onCompletion(ctx: usize, packet: [*c]c.tb_packet_t, _: u64, result: [*c]const u8, size: u32) callconv(.c) void {
        const shared: *Shared = @ptrFromInt(ctx);
        const request: *Request = @ptrCast(@alignCast(packet.*.user_data));
        request.status = packet.*.status;
        if (packet.*.status == c.TB_PACKET_OK and size > 0) {
            std.debug.assert(size <= request.reply.len);
            @memcpy(request.reply[0..size], result[0..size]);
            request.len = size;
        }
        // `request` lives on the waiting thread's stack: don't touch it
        // after this.
        request.done.set(shared.io);
    }
};

fn checkSchema(comptime S: type) void {
    if (!@hasDecl(S, "is_zom_schema"))
        @compileError("zom-tigerbeetle: Dataset takes a zom.Schema, found `" ++ @typeName(S) ++ "`");
    if (S.Tuple != tb.Account and S.Tuple != tb.Transfer and S.Tuple != tb.AccountBalance)
        @compileError("zom-tigerbeetle: TigerBeetle's schemas are fixed; schema \"" ++ S.name ++ "\" must be a zom.Schema of " ++
            "zom_tigerbeetle.tb.Account, .Transfer or .AccountBalance (or use zom_tigerbeetle.Account / .Transfer / .AccountBalance), found `" ++
            @typeName(S.Tuple) ++ "`");
    const pk = if (S.Tuple == tb.AccountBalance) "timestamp" else "id";
    if (!std.mem.eql(u8, @tagName(S.primary_key), pk))
        @compileError("zom-tigerbeetle: schema \"" ++ S.name ++ "\" must have `." ++ pk ++ "` as its primary key, found `." ++ @tagName(S.primary_key) ++ "`");
}

fn TbDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    const is_account = T == tb.Account;
    return struct {
        const Self = @This();

        shared: *Gateway.Shared,

        /// `tb.results.CreateAccountResult` or `.CreateTransferResult`.
        pub const Code = if (is_account) results.CreateAccountResult else results.CreateTransferResult;
        /// `tb.results.CreateAccountError` or `.CreateTransferError`.
        pub const CreateError = if (is_account) results.CreateAccountError else results.CreateTransferError;
        /// `insert` and `insertMany` fail with the gateway's errors, the
        /// result code's error (`error.ExceedsCredits`, ...),
        /// `error.DuplicatePrimaryKey` for the `exists*` codes, or
        /// `error.UnknownResult` for a code this client doesn't know.
        pub const InsertError = Gateway.Error || CreateError || results.OtherError;

        /// One row `insertManyResults` didn't create: its index in the rows
        /// passed in, and why.
        pub const Result = struct { index: usize, code: Code };

        /// One event's result in a `create_*` reply.
        pub const Reply = if (is_account) c.tb_create_account_result_t else c.tb_create_transfer_result_t;
        const operation = if (is_account) c.TB_OPERATION_CREATE_ACCOUNTS else c.TB_OPERATION_CREATE_TRANSFERS;
        const lookup_operation = if (is_account) c.TB_OPERATION_LOOKUP_ACCOUNTS else c.TB_OPERATION_LOOKUP_TRANSFERS;
        const query_operation = if (is_account) c.TB_OPERATION_QUERY_ACCOUNTS else c.TB_OPERATION_QUERY_TRANSFERS;

        /// Ids by `eq` and `in` (`supports.in`; `filterable` keeps `in` to
        /// `id`). No `or` groups, `like`, projection or join, and no
        /// `offset`: `query_*` can only start from a timestamp, so skipping
        /// rows means reading them, which `.fallback` does in the open.
        pub const supports: zom.Supports = .{ .in = true, .offset = false };
        /// `id` by `eq` / `in`, `user_data_128/64/32`, `ledger` and `code`
        /// by `eq`, `timestamp` by `eq`, `lt`, `lte`, `gt`, `gte` and
        /// `between`. See read.zig.
        pub const filterable = reads.filterable;
        /// `timestamp` only.
        pub const orderable = reads.orderable;

        /// `create_accounts` / `create_transfers` with one event. Returns
        /// the row as stored, with the `timestamp` the cluster gave it.
        pub fn insert(self: *Self, row: T) InsertError!T {
            var reply: [1]Reply = undefined;
            const replies = self.createBatch((&row)[0..1], &reply) catch |err| switch (err) {
                error.TooMuchData => unreachable, // createBatch: never for one event
                else => |e| return e,
            };
            if (errorFor(replies[0].status)) |err| return err;
            var stored = row;
            stored.timestamp = replies[0].timestamp;
            return stored;
        }

        /// Creates `rows` in requests of up to `batch_max` events, and
        /// returns how many were created, which is all of them unless it
        /// fails.
        ///
        /// TigerBeetle applies each event on its own (except linked
        /// chains), so a failure doesn't undo the others: every request is
        /// sent, and the rows that could be created are. The error is the
        /// first failing row's, skipping `error.LinkedEventFailed`, which
        /// only says another event of the row's chain failed (it is
        /// returned when nothing else failed). To know which rows failed,
        /// and why, use `insertManyResults` instead.
        ///
        /// A batch is never split inside a linked chain; a chain longer
        /// than the cluster's batch limit is `error.LinkedChainTooLong`.
        /// When it is longer than `batch_max` that is known before anything
        /// is sent; when the limit has to be found first, the batches
        /// before the chain are already sent.
        pub fn insertMany(self: *Self, rows: []const T) InsertError!usize {
            var first: FirstError = .{};
            const created = try self.createAll(rows, &first);
            if (first.err) |err| return err;
            if (first.linked_event_failed) return error.LinkedEventFailed;
            return created;
        }

        /// `insertMany`, but a row that isn't created is no error: the
        /// result lists every such row, in order, with its result code
        /// (`.exists`, `.exceeds_credits`, ...). An empty result means
        /// every row was created. Free it with `allocator`.
        ///
        /// The dataset is reached through the gateway, not a relation:
        /// `(try gateway.dataset(zom_tigerbeetle.Transfer)).insertManyResults(rows, allocator)`.
        pub fn insertManyResults(self: *Self, rows: []const T, allocator: Allocator) Gateway.Error![]Result {
            var list: ResultList = .{ .allocator = allocator };
            errdefer list.items.deinit(allocator);
            _ = try self.createAll(rows, &list);
            return list.items.toOwnedSlice(allocator);
        }

        /// `relation.linked()`: see linked.zig.
        pub fn LinkedChangeset(comptime Rel: type) type {
            return chains.LinkedChangeset(Rel);
        }

        /// The event that made a linked chain fail: its index in the chain,
        /// and its result code. The other events get `.linked_event_failed`,
        /// which is only the code here if no event said why.
        pub const ChainFailure = struct { index: usize, code: Code };

        /// Creates `rows`, one linked chain (every event but the last has
        /// `flags.linked`), in one request, so all of them are created or
        /// none is. Returns `rows.len`. On failure the error is the causing
        /// event's (`error.ExceedsCredits`, ...), and `failure`, when given,
        /// says which event it was. A chain longer than the cluster takes
        /// in one request is `error.LinkedChainTooLong`, and nothing is
        /// created. `reply` has room for one result per event.
        pub fn insertChain(self: *Self, rows: []const T, reply: []Reply, failure: ?*ChainFailure) InsertError!usize {
            std.debug.assert(rows.len > 0);
            for (rows, 0..) |row, i| std.debug.assert(isLinked(row) == (i + 1 < rows.len));
            if (rows.len > self.shared.batchLimit()) return error.LinkedChainTooLong;
            const replies = self.createBatch(rows, reply) catch |err| switch (err) {
                error.TooMuchData => return error.LinkedChainTooLong,
                else => |e| return e,
            };
            // The events that failed only because another one did are
            // `.linked_event_failed`; the cause is the other code.
            var cause: ?ChainFailure = null;
            for (replies, 0..) |r, index| {
                if (r.status == @intFromEnum(Code.created)) continue;
                const code: Code = @enumFromInt(r.status);
                if (cause == null or (cause.?.code == .linked_event_failed and code != .linked_event_failed))
                    cause = .{ .index = index, .code = code };
            }
            const found = cause orelse return rows.len;
            if (failure) |out| out.* = found;
            return errorFor(@intFromEnum(found.code)).?;
        }

        /// The rows matching `query`, through `lookup_*` or `query_*`
        /// (see read.zig). Every returned row is checked against the whole
        /// query, so any query is answered right; the relation only sends
        /// what `filterable` and `orderable` accept, which TigerBeetle
        /// evaluates itself. Without an order, a lookup's rows come in the
        /// order of the ids asked for, and a query's by `timestamp`. An
        /// `offset` (only from a direct call: `supports.offset` is false)
        /// is applied by reading the skipped rows.
        pub fn read(self: *Self, query: Q, allocator: Allocator) Gateway.Error![]T {
            const p = reads.plan(T, &query);
            var rows: Collect(T) = .{ .allocator = allocator };
            errdefer rows.items.deinit(allocator);
            // Sorting needs every match; otherwise the first offset + limit do.
            try self.scan(&query, p, if (p.sort) null else wanted(Q, &query), &rows);
            return finish(T, &rows, &query, p.sort);
        }

        /// How many rows `read` would return. TigerBeetle has no count, so
        /// this reads them, page by page, and keeps none: up to `offset +
        /// limit` rows, or every match, at most `Config.scan_max`.
        pub fn count(self: *Self, query: Q) Gateway.Error!usize {
            var counter: Counter(T) = .{};
            // The order changes which rows, not how many.
            try self.scan(&query, reads.plan(T, &query), wanted(Q, &query), &counter);
            const start, const end = reads.window(counter.n, query.offset, query.limit);
            return end - start;
        }

        /// Sends `p`'s requests and calls `sink.add(row)` for each row
        /// returned that matches `query`, in the order they come, until
        /// `want` have (null: all of them).
        fn scan(self: *Self, query: *const Q, p: reads.Plan, want: ?usize, sink: anytype) Gateway.Error!void {
            if (want == 0) return;
            switch (p.source) {
                .none => {},
                .lookup => |ids| {
                    var reply: [reads.lookup_max]T = undefined;
                    const rows = try self.shared.submitRecords(T, lookup_operation, std.mem.sliceAsBytes(ids.slice()), reply[0..ids.len]);
                    var matched: usize = 0;
                    for (rows) |row| {
                        if (!query.matches(row)) continue;
                        try sink.add(row);
                        matched += 1;
                        if (matched == want) return;
                    }
                },
                .query => |filter| try self.shared.scanPages(T, query_operation, filter, want, Matching(T, @TypeOf(sink)){ .query = query, .inner = sink }),
            }
        }

        /// Each key's rows of association `a` (declared on another schema,
        /// pointing at this one), for zom's `combine` (see combine.zig): one
        /// slice per key, in the order of `keys`, each read with `query`
        /// (the combined relation's) and allocated with `allocator`. How is
        /// chosen at compile time:
        ///
        /// - `Account.transfers` (`zom.customAssociation(.., .account_transfers, ..)`)
        ///   and a `hasMany` on `debit_account_id` / `credit_account_id`:
        ///   `get_account_transfers` for each account, both sides or the one
        ///   named. A transfer between two of the accounts is in both slices.
        /// - a `belongsTo`: `lookup_*` of the ids, `lookup_max` at a time.
        /// - a `hasMany` on `user_data_128/64/32`, `ledger` or `code`: one
        ///   read per key, `query.where(fk, .eq, key)`, through `query_*`.
        ///
        /// Anything else is a compile error. Each read is bounded by
        /// `Config.scan_max` on its own. The query's filters and order apply
        /// to each slice, whatever TigerBeetle evaluated (`Query.matches`
        /// checks every row, an order other than `timestamp` sorts it).
        pub fn loadAssociation(
            self: *Self,
            comptime a: zom.Association,
            keys: []const a.Key(),
            query: Q,
            allocator: Allocator,
        ) Gateway.Error![]const []const T {
            const how = comptime loadHow(a);
            const groups = try allocator.alloc([]const T, keys.len);
            switch (how) {
                .account_transfers => |sides| for (keys, groups) |id, *g| {
                    g.* = try self.accountTransfers(&query, id, sides, allocator);
                },
                .lookup => {
                    @memset(groups, &.{});
                    var start: usize = 0;
                    while (start < keys.len) : (start += reads.lookup_max) {
                        const chunk = keys[start..@min(start + reads.lookup_max, keys.len)];
                        const rows = try self.read(query.whereIn(.id, chunk), allocator);
                        // At most one row per id, so a key's group is that row.
                        for (rows, 0..) |row, r| for (chunk, start..) |id, k| {
                            if (row.id == id) groups[k] = rows[r..][0..1];
                        };
                    }
                },
                .by_field => |field| for (keys, groups) |key, *g| {
                    g.* = try self.read(query.where(field, .eq, key), allocator);
                },
            }
            return groups;
        }

        const How = union(enum) {
            account_transfers: u32,
            lookup,
            by_field: Q.Field,
        };

        fn loadHow(comptime a: zom.Association) How {
            const where = "zom-tigerbeetle: combine(." ++ a.name ++ ") from \"" ++ a.source.name ++ "\" into \"" ++ S.name ++ "\"";
            switch (a.kind) {
                .custom => {
                    if (is_account or !std.mem.eql(u8, a.tag, "account_transfers"))
                        @compileError(where ++ ": unknown custom association `." ++ a.tag ++ "` (the transfers dataset loads `.account_transfers`)");
                    if (a.Key() != u128)
                        @compileError(where ++ ": `.account_transfers` needs a u128 account id key, found `" ++ @typeName(a.Key()) ++ "`");
                    return .{ .account_transfers = c.TB_ACCOUNT_FILTER_DEBITS | c.TB_ACCOUNT_FILTER_CREDITS };
                },
                .belongs_to => return .lookup,
                .has_many => {
                    if (!is_account) {
                        if (std.mem.eql(u8, a.foreign_key, "debit_account_id")) return .{ .account_transfers = c.TB_ACCOUNT_FILTER_DEBITS };
                        if (std.mem.eql(u8, a.foreign_key, "credit_account_id")) return .{ .account_transfers = c.TB_ACCOUNT_FILTER_CREDITS };
                    }
                    for (reads.query_fields) |f| {
                        if (std.mem.eql(u8, a.foreign_key, f)) return .{ .by_field = std.meta.stringToEnum(Q.Field, f).? };
                    }
                    @compileError(where ++ ": TigerBeetle can't find rows by '" ++ a.foreign_key ++ "'; a hasMany needs " ++
                        (if (is_account) "" else "debit_account_id, credit_account_id, ") ++
                        "user_data_128, user_data_64, user_data_32, ledger or code as its foreign key");
                },
            }
        }

        /// `get_account_transfers` of one account, filtered and ordered by
        /// `query` (and windowed by its offset and limit, though `combine`
        /// passes none).
        fn accountTransfers(self: *Self, query: *const Q, account_id: u128, sides: u32, allocator: Allocator) Gateway.Error![]const T {
            const filter = reads.accountFilter(T, query, account_id, sides) orelse return &.{};
            const sort = reads.sorts(T, query);
            var rows: Collect(T) = .{ .allocator = allocator };
            errdefer rows.items.deinit(allocator);
            const sink: Matching(T, *Collect(T)) = .{ .query = query, .inner = &rows };
            try self.shared.scanPages(T, c.TB_OPERATION_GET_ACCOUNT_TRANSFERS, filter, if (sort) null else wanted(Q, query), sink);
            return finish(T, &rows, query, sort);
        }

        fn errorFor(status: u32) ?InsertError {
            const code: Code = @enumFromInt(status);
            const err = results.errorOf(Code, CreateError, code) orelse return null;
            if (err == error.UnknownResult) log.warn("unknown {s} result code {d}", .{ @typeName(Code), status });
            return err;
        }

        /// Sends `rows` in batches, calling `sink.failed(index, code)` for
        /// each row not created, and returns how many were. A batch the
        /// client refuses as too big is retried smaller (see
        /// `Gateway.batchLimit`), and nothing of it was applied.
        fn createAll(self: *Self, rows: []const T, sink: anytype) Gateway.Error!usize {
            if (rows.len == 0) return 0;
            const shared = self.shared;
            if (!chainsFit(T, rows, shared.batch_max)) return error.LinkedChainTooLong;

            const reply = try shared.allocator.alloc(Reply, @min(rows.len, shared.batch_max));
            defer shared.allocator.free(reply);

            var created: usize = 0;
            var start: usize = 0;
            while (start < rows.len) {
                const end = batchEnd(T, rows, start, shared.batchLimit()) orelse return error.LinkedChainTooLong;
                const replies = self.createBatch(rows[start..end], reply) catch |err| switch (err) {
                    // The limit is now below `end - start`, so this ends.
                    error.TooMuchData => continue,
                    else => |e| return e,
                };
                for (replies, start..) |r, index| {
                    if (r.status == @intFromEnum(Code.created)) {
                        created += 1;
                    } else {
                        try sink.failed(index, @as(Code, @enumFromInt(r.status)));
                    }
                }
                start = end;
            }
            return created;
        }

        /// One request. The reply has one result per event, in order.
        /// `error.TooMuchData`: the client refused it as bigger than the
        /// cluster takes, which is recorded so the next try is smaller.
        fn createBatch(self: *Self, batch: []const T, reply: []Reply) (Gateway.Error || error{TooMuchData})![]const Reply {
            const shared = self.shared;
            std.debug.assert(batch.len > 0);
            std.debug.assert(batch.len <= shared.batch_max);
            std.debug.assert(reply.len >= batch.len);
            const n: u32 = @intCast(batch.len);
            const len = shared.submit(operation, std.mem.sliceAsBytes(batch), std.mem.sliceAsBytes(reply)) catch |err| switch (err) {
                error.TooMuchData => {
                    // Every cluster takes one event; refusing it is a bug.
                    if (n == 1) return error.Unexpected;
                    _ = shared.too_big.fetchMin(n, .monotonic);
                    log.debug("the cluster refused {d} events; batches are now up to {d}", .{ n, shared.batchLimit() });
                    return error.TooMuchData;
                },
                else => |e| return e,
            };
            if (len != batch.len * @sizeOf(Reply)) {
                log.debug("{d} events got a reply of {d} bytes", .{ batch.len, len });
                return error.Unexpected;
            }
            _ = shared.fits.fetchMax(n, .monotonic);
            return reply[0..batch.len];
        }

        const FirstError = struct {
            err: ?InsertError = null,
            linked_event_failed: bool = false,

            fn failed(self: *FirstError, _: usize, code: Code) error{}!void {
                const err = errorFor(@intFromEnum(code)).?;
                if (err == error.LinkedEventFailed) {
                    self.linked_event_failed = true;
                } else if (self.err == null) {
                    self.err = err;
                }
            }
        };

        const ResultList = struct {
            allocator: Allocator,
            items: std.ArrayList(Result) = .empty,

            fn failed(self: *ResultList, index: usize, code: Code) Allocator.Error!void {
                try self.items.append(self.allocator, .{ .index = index, .code = code });
            }
        };
    };
}

/// The read-only balance view: `zom_tigerbeetle.AccountBalance`, rows of
/// `tb.AccountBalance`, read through `get_account_balances`, one account
/// at a time. A read needs a top-level `account_id` filter (`eq` or `in`,
/// so `whereIn` and `combine(.balances, ...)` work); without one it is
/// `error.AccountIdRequired`, since TigerBeetle can't list every account's
/// history. `timestamp` ranges and a `timestamp` order go to the cluster;
/// the other filters (balances by value) are `allowFallback()` ones, and
/// `offset` too. Only accounts created with `flags.history` have rows.
fn BalanceDataset(comptime S: type) type {
    const T = S.Tuple;
    const Q = zom.Query(T);
    return struct {
        const Self = @This();

        shared: *Gateway.Shared,

        pub const ReadError = Gateway.Error || error{
            /// The query has no `account_id` filter by `eq` or `in`.
            AccountIdRequired,
        };

        pub const supports: zom.Supports = .{ .in = true, .offset = false };

        /// `account_id` by `eq` / `in`; `timestamp` by `eq`, `lt`, `lte`,
        /// `gt`, `gte` and `between`.
        pub fn filterable(comptime field: []const u8, comptime op: zom.Op) bool {
            if (comptime std.mem.eql(u8, field, "account_id")) return op == .eq or op == .in;
            if (comptime std.mem.eql(u8, field, "timestamp")) return reads.filterable(field, op);
            return false;
        }

        /// `timestamp` only.
        pub const orderable = reads.orderable;

        /// The balances matching `query`, account by account in the order
        /// of its `account_id` filter, each by `timestamp` (descending with
        /// `order(.timestamp, .desc)`). Several accounts with an order, or
        /// an order by anything but `timestamp`, are sorted in memory.
        pub fn read(self: *Self, query: Q, allocator: Allocator) ReadError![]T {
            var rows: Collect(T) = .{ .allocator = allocator };
            errdefer rows.items.deinit(allocator);
            const sort = try self.scan(&query, true, &rows);
            return finish(T, &rows, &query, sort);
        }

        /// How many rows `read` would return; it reads them, as `count`
        /// does on the other datasets.
        pub fn count(self: *Self, query: Q) ReadError!usize {
            var counter: Counter(T) = .{};
            _ = try self.scan(&query, false, &counter);
            const start, const end = reads.window(counter.n, query.offset, query.limit);
            return end - start;
        }

        /// One `get_account_balances` scan per account. Returns whether the
        /// rows must still be sorted, which only a read (`ordered`) does: a
        /// count doesn't care about order.
        fn scan(self: *Self, query: *const Q, ordered: bool, sink: anytype) ReadError!bool {
            const ids = reads.idsOf(T, query, .account_id) orelse return error.AccountIdRequired;
            const sort = ordered and query.orderSlice().len > 0 and (ids.len > 1 or reads.sorts(T, query));
            // Without a sort, the first offset + limit matches are enough.
            const want = if (sort) null else wanted(Q, query);
            var kept: usize = 0;
            for (ids.slice()) |id| {
                const remaining = if (want) |w| w - kept else null;
                if (remaining == 0) break;
                const filter = reads.accountFilter(T, query, id, c.TB_ACCOUNT_FILTER_DEBITS | c.TB_ACCOUNT_FILTER_CREDITS) orelse continue;
                const each: BalanceSink(@TypeOf(sink)) = .{ .account_id = id, .query = query, .inner = sink, .kept = &kept };
                try self.shared.scanPages(c.tb_account_balance_t, c.TB_OPERATION_GET_ACCOUNT_BALANCES, filter, remaining, each);
            }
            return sort;
        }

        fn BalanceSink(comptime Inner: type) type {
            return struct {
                account_id: u128,
                query: *const Q,
                inner: Inner,
                kept: *usize,

                fn take(self: @This(), raw: c.tb_account_balance_t) !bool {
                    const row = T.of(self.account_id, raw);
                    if (!self.query.matches(row)) return false;
                    try self.inner.add(row);
                    self.kept.* += 1;
                    return true;
                }
            };
        }
    };
}

/// The matches a read needs, null for all: `offset + limit`.
fn wanted(comptime Q: type, query: *const Q) ?usize {
    const l = query.limit orelse return null;
    if (l == 0) return 0;
    return std.math.add(usize, l, query.offset) catch null;
}

/// The rows a read collected, sorted by `query` when `sort`, then cut to its
/// offset and limit, as an owned slice.
fn finish(comptime T: type, rows: *Collect(T), query: *const zom.Query(T), sort: bool) Allocator.Error![]T {
    const items = rows.items.items;
    if (sort) std.mem.sort(T, items, query.orderSlice(), zom.Query(T).lessThan);
    const start, const end = reads.window(items.len, query.offset, query.limit);
    std.mem.copyForwards(T, items[0 .. end - start], items[start..end]);
    rows.items.shrinkRetainingCapacity(end - start);
    return rows.items.toOwnedSlice(rows.allocator);
}

fn Collect(comptime T: type) type {
    return struct {
        allocator: Allocator,
        items: std.ArrayList(T) = .empty,

        fn add(self: *@This(), row: T) Allocator.Error!void {
            try self.items.append(self.allocator, row);
        }
    };
}

fn Counter(comptime T: type) type {
    return struct {
        n: usize = 0,

        fn add(self: *@This(), _: T) error{}!void {
            self.n += 1;
        }
    };
}

/// A `scanPages` sink keeping the rows that match `query`, into `inner`.
fn Matching(comptime T: type, comptime Inner: type) type {
    return struct {
        query: *const zom.Query(T),
        inner: Inner,

        fn take(self: @This(), row: T) !bool {
            if (!self.query.matches(row)) return false;
            try self.inner.add(row);
            return true;
        }
    };
}

fn isLinked(row: anytype) bool {
    return row.flags & tb.linked_flag != 0;
}

/// False when `rows` has a linked chain longer than `max` events, which no
/// request can hold. A chain is a run of linked events and the event after
/// them, which closes it; an unclosed run at the end counts as is.
fn chainsFit(comptime T: type, rows: []const T, max: u32) bool {
    var run: usize = 0;
    for (rows) |row| {
        if (isLinked(row)) {
            run += 1;
            if (run >= max) return false;
        } else {
            run = 0;
        }
    }
    return true;
}

/// Where the batch starting at `start` ends: `max` rows on, or sooner so
/// as to end after the last unlinked event and keep a chain whole. Null
/// when the `max` rows are all linked, so the chain starting at `start`
/// (which is 0 or follows an unlinked event) is longer than `max`.
fn batchEnd(comptime T: type, rows: []const T, start: usize, max: u32) ?usize {
    std.debug.assert(max > 0);
    const end = @min(start + max, rows.len);
    if (end == rows.len) return end;
    var j = end;
    while (j > start) : (j -= 1) {
        if (!isLinked(rows[j - 1])) return j;
    }
    return null;
}

const testing = std.testing;

fn linkedRows(comptime pattern: []const u8) [pattern.len]tb.Transfer {
    var rows: [pattern.len]tb.Transfer = undefined;
    for (&rows, pattern, 0..) |*row, ch, i| row.* = .{ .id = i + 1, .flags = if (ch == 'L') tb.linked_flag else 0 };
    return rows;
}

test "batches are cut at batch_max, but never inside a linked chain" {
    // `L` is linked, `.` closes a chain or stands alone.
    const rows = linkedRows("..LL.LLL...");
    try testing.expect(chainsFit(tb.Transfer, &rows, 4));
    // A window of 4 rows would cut "LL." after "LL": end after the ".." instead.
    try testing.expectEqual(2, batchEnd(tb.Transfer, &rows, 0, 4));
    try testing.expectEqual(5, batchEnd(tb.Transfer, &rows, 2, 4));
    try testing.expectEqual(9, batchEnd(tb.Transfer, &rows, 5, 4));
    try testing.expectEqual(11, batchEnd(tb.Transfer, &rows, 9, 4));
    // Without chains, batches are full.
    const plain = linkedRows("..........");
    try testing.expectEqual(4, batchEnd(tb.Transfer, &plain, 0, 4));
    try testing.expectEqual(10, batchEnd(tb.Transfer, &plain, 8, 4));
}

test "a chain longer than batch_max doesn't fit" {
    try testing.expect(!chainsFit(tb.Transfer, &linkedRows(".LLLL."), 4));
    try testing.expect(chainsFit(tb.Transfer, &linkedRows(".LLL."), 4));
    try testing.expect(!chainsFit(tb.Transfer, &linkedRows("LLLL"), 4));
    // Once the cluster's limit is known to be lower than batch_max.
    try testing.expectEqual(null, batchEnd(tb.Transfer, &linkedRows("LLLL."), 0, 3));
}

/// The live tests run against `ZOM_TB_ADDRESSES` (e.g. `3000`), on cluster
/// 0, and are skipped when it isn't set. A dev cluster:
///
///     tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development 0_0.tigerbeetle
///     tigerbeetle start --addresses=3000 --development 0_0.tigerbeetle
fn testGateway(config: struct { batch_max: u32 = tb.batch_max, scan_max: u64 = 1 << 20 }) !Gateway {
    const addresses = testing.environ.getAlloc(testing.allocator, "ZOM_TB_ADDRESSES") catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => |e| return e,
    };
    defer testing.allocator.free(addresses);
    return Gateway.init(testing.allocator, .{
        .io = testing.io,
        .cluster_id = 0,
        .addresses = addresses,
        .batch_max = config.batch_max,
        .scan_max = config.scan_max,
    });
}

/// Ids no earlier run created: the cluster keeps its data between runs.
/// Above maxInt(u64), to check u128 ids get through whole.
fn freshIds() u128 {
    var bytes: [8]u8 = undefined;
    testing.io.random(&bytes);
    return (@as(u128, std.mem.readInt(u64, &bytes, .little) | 1) << 64);
}

test "init connects: a lookup of an unknown id round-trips with no result" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();

    const ids = [_]u128{freshIds()};
    var reply: [@sizeOf(tb.Account)]u8 align(16) = undefined;
    const len = try gateway.shared.submit(c.TB_OPERATION_LOOKUP_ACCOUNTS, std.mem.sliceAsBytes(&ids), &reply);
    try testing.expectEqual(0, len);
}

const Accounts = zom.Relation(schemas.Account, Gateway);
const Transfers = zom.Relation(schemas.Transfer, Gateway);

test "insert: an account is created once, then is a DuplicatePrimaryKey" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);

    const id = freshIds();
    const stored = try accounts.create(.{ .id = id, .ledger = 700, .code = 10 }).commit();
    try testing.expectEqual(id, stored.id);
    try testing.expect(stored.timestamp != 0);

    try testing.expectError(error.DuplicatePrimaryKey, accounts.create(.{ .id = id, .ledger = 700, .code = 10 }).commit());
    // Same id, other fields: still the id that's taken.
    try testing.expectError(error.DuplicatePrimaryKey, accounts.create(.{ .id = id, .ledger = 701, .code = 10 }).commit());
    // A code of its own.
    try testing.expectError(error.LedgerMustNotBeZero, accounts.create(.{ .id = id + 1, .ledger = 0, .code = 10 }).commit());
}

test "insertMany: 10,000 transfers go in 2 requests" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const transfers = try Transfers.init(&gateway);

    const base = freshIds();
    try testing.expectEqual(2, try accounts.createMany(&.{
        .{ .id = base + 1, .ledger = 700, .code = 10 },
        .{ .id = base + 2, .ledger = 700, .code = 10 },
    }).commit());

    const rows = try testing.allocator.alloc(tb.Transfer, 10_000);
    defer testing.allocator.free(rows);
    for (rows, 0..) |*row, i| row.* = .{
        .id = base + 100 + i,
        .debit_account_id = base + 1,
        .credit_account_id = base + 2,
        .amount = 1,
        .ledger = 700,
        .code = 1,
        .user_data_128 = base,
    };

    // A --development cluster takes 253 events per request, not 8189: the
    // first batch finds that out. So that the count below is exact either
    // way, a first round of 10,000 learns the limit.
    try testing.expectEqual(10_000, try transfers.createMany(rows).commit());
    const limit = gateway.batchLimit();
    try testing.expect(limit == tb.batch_max or limit == 253);

    for (rows) |*row| row.id += rows.len;
    const before = gateway.requestCount();
    try testing.expectEqual(10_000, try transfers.createMany(rows).commit());
    // 8189 + 1811 on a production cluster; 40 on a development one.
    try testing.expectEqual(try std.math.divCeil(usize, rows.len, limit), gateway.requestCount() - before);
    if (limit == tb.batch_max) try testing.expectEqual(2, gateway.requestCount() - before);

    // Reads page through `query_*` replies of up to 8189 rows, whatever the
    // cluster's request limit: 20,000 rows are 3 pages, 9000 are 2.
    const tagged = transfers.where(.user_data_128, .eq, base);
    const read_before = gateway.requestCount();
    try testing.expectEqual(20_000, try tagged.count());
    try testing.expectEqual(3, gateway.requestCount() - read_before);
    const newest = try tagged.order(.timestamp, .desc).limit(9000).toSlice(testing.allocator);
    defer testing.allocator.free(newest);
    try testing.expectEqual(9000, newest.len);
    try testing.expectEqual(5, gateway.requestCount() - read_before);
    // The last row created comes first, and the timestamps strictly fall
    // across the page boundary.
    try testing.expectEqual(rows[rows.len - 1].id, newest[0].id);
    for (newest[1..], newest[0 .. newest.len - 1]) |row, prev| try testing.expect(row.timestamp < prev.timestamp);
}

test "the batch limit is found without losing rows" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);

    const rows = try testing.allocator.alloc(tb.Account, 3000);
    defer testing.allocator.free(rows);
    const base = freshIds();
    for (rows, 0..) |*row, i| row.* = .{ .id = base + i, .ledger = 700, .code = 10 };
    // On a --development cluster the first tries are refused; every row is
    // still created, once.
    try testing.expectEqual(rows.len, try accounts.createMany(rows).commit());
    try testing.expectError(error.DuplicatePrimaryKey, accounts.create(rows[rows.len - 1]).commit());
}

test "an overdraft is rejected with a typed error, and insertManyResults says which row" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const transfers = try Transfers.init(&gateway);

    const base = freshIds();
    const strict = tb.AccountFlags.bits(.{ .debits_must_not_exceed_credits = true });
    _ = try accounts.createMany(&.{
        .{ .id = base + 1, .ledger = 700, .code = 10, .flags = strict },
        .{ .id = base + 2, .ledger = 700, .code = 10 },
    }).commit();

    // Fund account 1 with 10 from account 2, then try to send 11 back.
    _ = try transfers.create(.{ .id = base + 10, .debit_account_id = base + 2, .credit_account_id = base + 1, .amount = 10, .ledger = 700, .code = 1 }).commit();
    const overdraft: tb.Transfer = .{ .id = base + 11, .debit_account_id = base + 1, .credit_account_id = base + 2, .amount = 11, .ledger = 700, .code = 1 };
    try testing.expectError(error.ExceedsCredits, transfers.create(overdraft).commit());

    // In a batch: the row after it is still created.
    const batch = [_]tb.Transfer{
        .{ .id = base + 12, .debit_account_id = base + 1, .credit_account_id = base + 2, .amount = 11, .ledger = 700, .code = 1 },
        .{ .id = base + 13, .debit_account_id = base + 1, .credit_account_id = base + 2, .amount = 4, .ledger = 700, .code = 1 },
        .{ .id = base + 14, .debit_account_id = base + 1, .credit_account_id = base + 1, .amount = 1, .ledger = 700, .code = 1 },
    };
    const dataset = try gateway.dataset(schemas.Transfer);
    const failed = try dataset.insertManyResults(&batch, testing.allocator);
    defer testing.allocator.free(failed);
    try testing.expectEqual(2, failed.len);
    try testing.expectEqual(0, failed[0].index);
    try testing.expectEqual(.exceeds_credits, failed[0].code);
    try testing.expectEqual(2, failed[1].index);
    try testing.expectEqual(.accounts_must_be_different, failed[1].code);

    // A failed transfer's id stays taken (`id_already_failed`), so insertMany
    // gets new ids. It reports the first failure.
    var again = batch;
    for (&again) |*t| t.id += 100;
    try testing.expectError(error.ExceedsCredits, dataset.insertMany(&again));
    // Resending a failed transfer as is.
    try testing.expectError(error.IdAlreadyFailed, transfers.create(batch[0]).commit());
}

test "a linked chain fails as a whole, and isn't split across requests" {
    // Batches of 3, so the chain of 3 below can't start a batch at row 1.
    var gateway = try testGateway(.{ .batch_max = 3 });
    defer gateway.deinit();
    const accounts = try gateway.dataset(schemas.Account);

    const base = freshIds();
    const linked = tb.linked_flag;
    const rows = [_]tb.Account{
        .{ .id = base + 1, .ledger = 700, .code = 10 },
        .{ .id = base + 2, .ledger = 700, .code = 10, .flags = linked },
        .{ .id = base + 3, .ledger = 700, .code = 10, .flags = linked },
        .{ .id = base + 4, .ledger = 0, .code = 10 }, // fails, so 2 and 3 do too
    };
    const before = gateway.requestCount();
    const failed = try accounts.insertManyResults(&rows, testing.allocator);
    defer testing.allocator.free(failed);
    // [1] then [2, 3, 4]: cutting at 3 rows would have left the chain open.
    try testing.expectEqual(2, gateway.requestCount() - before);
    try testing.expectEqual(3, failed.len);
    try testing.expectEqual(.linked_event_failed, failed[0].code);
    try testing.expectEqual(.linked_event_failed, failed[1].code);
    try testing.expectEqual(.ledger_must_not_be_zero, failed[2].code);

    // insertMany names the cause, not linked_event_failed.
    const retry = [_]tb.Account{ rows[1], rows[2], rows[3] };
    try testing.expectError(error.LedgerMustNotBeZero, accounts.insertMany(&retry));

    const too_long = [_]tb.Account{ rows[1], rows[2], rows[2], rows[3] };
    try testing.expectError(error.LinkedChainTooLong, accounts.insertMany(&too_long));
}

test "linked(): a chain with an invalid second transfer creates none of them" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const transfers = try Transfers.init(&gateway);
    const alloc = testing.allocator;

    const base = freshIds();
    const a = base + 1;
    const b = base + 2;
    _ = try accounts.createMany(&.{
        .{ .id = a, .ledger = 700, .code = 10 },
        .{ .id = b, .ledger = 700, .code = 10 },
    }).commit();
    const t1: tb.Transfer = .{ .id = base + 10, .debit_account_id = a, .credit_account_id = b, .amount = 10, .ledger = 700, .code = 1 };
    const t2: tb.Transfer = .{ .id = base + 11, .debit_account_id = b, .credit_account_id = base + 99, .amount = 5, .ledger = 700, .code = 1 };
    const t3: tb.Transfer = .{ .id = base + 12, .debit_account_id = b, .credit_account_id = a, .amount = 1, .ledger = 700, .code = 1 };

    // One request; the cause's error, not linked_event_failed, and which
    // event it was.
    var failure: Transfers.Linked().Failure = undefined;
    var before = gateway.requestCount();
    try testing.expectError(error.CreditAccountNotFound, transfers.linked().add(t1).add(t2).add(t3).reportTo(&failure).commit());
    try testing.expectEqual(1, gateway.requestCount() - before);
    try testing.expectEqual(1, failure.index);
    try testing.expectEqual(.credit_account_not_found, failure.code);
    const ids = [_]u128{ t1.id, t2.id, t3.id };
    const none = try transfers.whereIn(.id, &ids).toSlice(alloc);
    defer alloc.free(none);
    try testing.expectEqual(0, none.len);
    // And no balance moved.
    try testing.expectEqual(0, (try accounts.byPk(a).one(alloc)).?.debits_posted);

    // A transient error (an account not found) spends the failing id:
    // TigerBeetle won't take it again, even fixed.
    var fixed = t2;
    fixed.credit_account_id = a;
    try testing.expectError(error.IdAlreadyFailed, transfers.linked().add(t1).add(fixed).add(t3).reportTo(&failure).commit());
    try testing.expectEqual(1, failure.index);

    // The events that only got linked_event_failed keep their ids: fixed
    // under a new id, the chain creates all three, in one request, linked
    // but for the last as stored.
    fixed.id = base + 13;
    before = gateway.requestCount();
    try testing.expectEqual(3, try transfers.linked().add(t1).add(fixed).add(t3).commit());
    try testing.expectEqual(1, gateway.requestCount() - before);
    const all = try transfers.whereIn(.id, &[_]u128{ t1.id, fixed.id, t3.id }).toSlice(alloc);
    defer alloc.free(all);
    try testing.expectEqual(3, all.len);
    for (all, [_]bool{ true, true, false }) |row, link| try testing.expectEqual(link, tb.TransferFlags.of(row).linked);

    // Created again: the first is `.exists`, the chain fails at 0.
    try testing.expectError(error.DuplicatePrimaryKey, transfers.linked().add(t1).add(fixed).reportTo(&failure).commit());
    try testing.expectEqual(0, failure.index);

    // An empty chain sends nothing.
    before = gateway.requestCount();
    try testing.expectEqual(0, try transfers.linked().commit());
    try testing.expectEqual(0, gateway.requestCount() - before);
}

test "linked(): a chain longer than a request holds is refused unsent" {
    var gateway = try testGateway(.{ .batch_max = 2 });
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const base = freshIds();
    const before = gateway.requestCount();
    try testing.expectError(error.LinkedChainTooLong, accounts.linked()
        .add(.{ .id = base + 1, .ledger = 700, .code = 10 })
        .add(.{ .id = base + 2, .ledger = 700, .code = 10 })
        .add(.{ .id = base + 3, .ledger = 700, .code = 10 })
        .commit());
    try testing.expectEqual(0, gateway.requestCount() - before);
    try testing.expectEqual(null, try accounts.byPk(base + 1).one(testing.allocator));
}

/// Six accounts tagged with a fresh `user_data_128`, so a query can find
/// them among every earlier run's, created one at a time so their
/// timestamps (returned) go up with the index. Row `i` has ledger 700 + i
/// % 2, code 10 + i / 3, `user_data_64` i % 2 and `user_data_32` i.
fn seedAccounts(accounts: Accounts) !struct { u128, [6]tb.Account } {
    const tag = freshIds();
    var stored: [6]tb.Account = undefined;
    for (&stored, 0..) |*row, i| row.* = try accounts.create(.{
        .id = tag + i,
        .user_data_128 = tag,
        .user_data_64 = i % 2,
        .user_data_32 = @intCast(i),
        .ledger = @intCast(700 + i % 2),
        .code = @intCast(10 + i / 3),
    }).commit();
    return .{ tag, stored };
}

/// Checks that `rows` are `seeded[indices]`, in order.
fn expectRows(seeded: []const tb.Account, indices: []const usize, rows: []const tb.Account) !void {
    errdefer {
        std.debug.print("expected rows", .{});
        for (indices) |i| std.debug.print(" {d}", .{i});
        std.debug.print(", found", .{});
        for (rows) |row| std.debug.print(" {d}", .{row.id - seeded[0].id});
        std.debug.print("\n", .{});
    }
    try testing.expectEqual(indices.len, rows.len);
    for (indices, rows) |i, row| try testing.expectEqual(seeded[i], row);
}

/// Reads `rel` and checks it returns `seeded[indices]` in order, that its
/// count agrees, and that it took `requests` requests to the cluster.
fn expectRead(gateway: *const Gateway, rel: anytype, seeded: []const tb.Account, indices: []const usize, requests: u64) !void {
    const before = gateway.requestCount();
    const rows = try rel.toSlice(testing.allocator);
    defer testing.allocator.free(rows);
    try expectRows(seeded, indices, rows);
    try testing.expectEqual(requests, gateway.requestCount() - before);
    const n = if (@TypeOf(rel).mode == .fallback) try rel.count(testing.allocator) else try rel.count();
    try testing.expectEqual(indices.len, n);
}

test "byPk and where(.id, .in, ...) are one lookup_* each" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const tag, const seeded = try seedAccounts(accounts);
    const a = testing.allocator;

    try expectRead(&gateway, accounts.byPk(tag + 2), &seeded, &.{2}, 1);
    try testing.expectEqual(seeded[4], (try accounts.byPk(tag + 4).one(a)).?);
    try testing.expectEqual(null, try accounts.byPk(tag + 99).one(a));
    // In the order asked; an unknown id is skipped and a repeated one read once.
    const mixed = [_]u128{ tag + 3, tag + 99, tag + 1, tag + 3 };
    try expectRead(&gateway, accounts.whereIn(.id, &mixed), &seeded, &.{ 3, 1 }, 1);
    // Other filters and an order are applied to the looked-up rows: still
    // one request.
    const four = [_]u128{ tag + 1, tag + 2, tag + 3, tag + 4 };
    try expectRead(&gateway, accounts.whereIn(.id, &four).where(.code, .eq, 11).order(.timestamp, .desc), &seeded, &.{ 4, 3 }, 1);
    try expectRead(&gateway, accounts.whereIn(.id, &four).limit(2), &seeded, &.{ 1, 2 }, 1);
}

test "eq on user_data and ledger/code, and timestamp ranges, are one query_*" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const tag, const s = try seedAccounts(accounts);
    const rel = accounts.where(.user_data_128, .eq, tag);

    try expectRead(&gateway, rel, &s, &.{ 0, 1, 2, 3, 4, 5 }, 1);
    try expectRead(&gateway, rel.where(.ledger, .eq, 701), &s, &.{ 1, 3, 5 }, 1);
    try expectRead(&gateway, rel.where(.code, .eq, 11).where(.ledger, .eq, 700), &s, &.{4}, 1);
    try expectRead(&gateway, rel.where(.user_data_64, .eq, 1).where(.user_data_32, .eq, 3), &s, &.{3}, 1);
    try expectRead(&gateway, rel.where(.timestamp, .gte, s[2].timestamp).where(.timestamp, .lte, s[4].timestamp), &s, &.{ 2, 3, 4 }, 1);
    try expectRead(&gateway, rel.where(.timestamp, .gt, s[2].timestamp).where(.timestamp, .lt, s[4].timestamp), &s, &.{3}, 1);
    try expectRead(&gateway, rel.where(.timestamp, .between, .{ s[1].timestamp, s[2].timestamp }), &s, &.{ 1, 2 }, 1);
    try expectRead(&gateway, rel.where(.timestamp, .eq, s[5].timestamp), &s, &.{5}, 1);
    // No user_data_128 filter: a timestamp range alone.
    try expectRead(&gateway, accounts.where(.timestamp, .between, .{ s[0].timestamp, s[1].timestamp }), &s, &.{ 0, 1 }, 1);
    // A contradiction sends nothing.
    try expectRead(&gateway, rel.where(.ledger, .eq, 700).where(.ledger, .eq, 701), &s, &.{}, 0);
    try expectRead(&gateway, rel.where(.timestamp, .gt, s[3].timestamp).where(.timestamp, .lt, s[2].timestamp), &s, &.{}, 0);
}

test "order(.timestamp, .desc) is the reversed flag, and limit the filter's limit" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const tag, const s = try seedAccounts(accounts);
    const rel = accounts.where(.user_data_128, .eq, tag);

    try expectRead(&gateway, rel.order(.timestamp, .desc), &s, &.{ 5, 4, 3, 2, 1, 0 }, 1);
    try expectRead(&gateway, rel.order(.timestamp, .asc).limit(2), &s, &.{ 0, 1 }, 1);
    try expectRead(&gateway, rel.order(.timestamp, .desc).limit(2), &s, &.{ 5, 4 }, 1);
    try expectRead(&gateway, rel.where(.ledger, .eq, 700).order(.timestamp, .desc).limit(1), &s, &.{4}, 1);
    try expectRead(&gateway, rel.limit(100), &s, &.{ 0, 1, 2, 3, 4, 5 }, 1);
    try expectRead(&gateway, rel.limit(0), &s, &.{}, 0);
    try testing.expectEqual(s[5], (try rel.order(.timestamp, .desc).first(testing.allocator)).?);
    try testing.expectError(error.MoreThanOneTuple, rel.where(.ledger, .eq, 700).one(testing.allocator));
}

test "a value a QueryFilter can't hold is filtered as rows come, paging on" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const tag, const s = try seedAccounts(accounts);
    const rel = accounts.where(.user_data_128, .eq, tag);

    // `user_data_64 = 0` turns that filter off: rows 1, 3 and 5 come back
    // too and are dropped. The first page asks for 3 rows (0, 1, 2) and
    // keeps 2, so a second page goes on from row 3.
    try expectRead(&gateway, rel.where(.user_data_64, .eq, 0).limit(3), &s, &.{ 0, 2, 4 }, 2);
    // Newest first: 5, 4 then 3, 2.
    try expectRead(&gateway, rel.where(.user_data_64, .eq, 0).order(.timestamp, .desc).limit(2), &s, &.{ 4, 2 }, 2);
    // No limit: one page holds all six.
    try expectRead(&gateway, rel.where(.user_data_64, .eq, 0), &s, &.{ 0, 2, 4 }, 1);
}

test "scan_max bounds a read: error.ScanLimitExceeded" {
    var gateway = try testGateway(.{ .scan_max = 4 });
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const tag, const s = try seedAccounts(accounts);
    const rel = accounts.where(.user_data_128, .eq, tag);

    try testing.expectError(error.ScanLimitExceeded, rel.count());
    try testing.expectError(error.ScanLimitExceeded, rel.toSlice(testing.allocator));
    // A limit within it is fine, and so is a lookup.
    try expectRead(&gateway, rel.limit(4), &s, &.{ 0, 1, 2, 3 }, 1);
    const all = [_]u128{ tag, tag + 1, tag + 2, tag + 3, tag + 4, tag + 5 };
    try expectRead(&gateway, rel.whereIn(.id, &all), &s, &.{ 0, 1, 2, 3, 4, 5 }, 1);
}

test "allowFallback: other filters, orders and offset run in memory" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const tag, const s = try seedAccounts(accounts);
    const rel = accounts.where(.user_data_128, .eq, tag).allowFallback();

    try expectRead(&gateway, rel.where(.user_data_32, .gt, 3), &s, &.{ 4, 5 }, 1);
    try expectRead(&gateway, rel.where(.code, .neq, 10).where(.ledger, .eq, 701), &s, &.{ 3, 5 }, 1);
    try expectRead(&gateway, rel.order(.user_data_32, .desc).limit(2), &s, &.{ 5, 4 }, 1);
    // The timestamp order and the limit go to the cluster as offset + limit.
    try expectRead(&gateway, rel.order(.timestamp, .desc).offset(1).limit(2), &s, &.{ 4, 3 }, 1);
    try expectRead(&gateway, rel.offset(4), &s, &.{ 4, 5 }, 1);
    try expectRead(&gateway, rel.whereAny(.{ .{ .user_data_32, .eq, 1 }, .{ .code, .eq, 11 } }), &s, &.{ 1, 3, 4, 5 }, 1);
}

// zom.lint can't run here: it defines its own schema, and TigerBeetle's
// two are fixed. This runs its read checks' kinds of queries (every
// supported op, an `in`, ranges, groups, orders, limit and offset) on
// six accounts instead, and checks each against the same query evaluated
// in memory on the seeded rows: `Query.matches`, then a stable sort and
// the window, as the memory adapter does. Without an order a query
// returns rows by timestamp, the order they were seeded in.
//
// Lint's insert checks have counterparts above ("insert: ...",
// "insertMany: ..."). Its update and delete checks can't apply, and are
// reported skipped in lint's own words, with the capability each lacks.
test "lint read checks: every query agrees with the same one in memory" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    inline for (.{ schemas.Account, schemas.Transfer }) |S| {
        const skips = comptime zom.lint.capabilitySkips(Gateway, S);
        comptime std.debug.assert(skips.len == 2);
        comptime std.debug.assert(std.mem.startsWith(u8, skips[0].check, "update:"));
        comptime std.debug.assert(std.mem.startsWith(u8, skips[1].check, "delete:"));
        _ = zom.lint.printSkips(Gateway, S);
    }
    const accounts = try Accounts.init(&gateway);
    const tag, const s = try seedAccounts(accounts);
    const rel = accounts.where(.user_data_128, .eq, tag);
    const any = rel.allowFallback();
    const ts = s[3].timestamp;
    const ids = [_]u128{ tag + 1, tag + 4, tag + 77 };

    const cases = .{
        rel,
        rel.where(.ledger, .eq, 700),
        rel.where(.code, .eq, 11).where(.user_data_64, .eq, 1),
        rel.where(.user_data_32, .eq, 2),
        rel.where(.timestamp, .eq, ts),
        rel.where(.timestamp, .lt, ts),
        rel.where(.timestamp, .lte, ts),
        rel.where(.timestamp, .gt, ts),
        rel.where(.timestamp, .gte, ts),
        rel.where(.timestamp, .between, .{ s[1].timestamp, ts }),
        rel.whereIn(.id, &ids),
        rel.order(.timestamp, .desc).limit(3),
        rel.where(.user_data_64, .eq, 0).order(.timestamp, .desc),
        any.where(.user_data_32, .neq, 2),
        any.where(.user_data_32, .lt, 2),
        any.where(.user_data_32, .between, .{ 1, 3 }),
        any.where(.user_data_32, .in, .{ 0, 5, 9 }),
        any.where(.user_data_32, .not_in, .{ 0, 5 }),
        any.whereNot(.{ .ledger, .eq, 700 }),
        any.whereAny(.{ .{ .user_data_32, .eq, 0 }, zom.all(.{ .{ .ledger, .eq, 701 }, .{ .code, .eq, 11 } }) }),
        any.order(.ledger, .desc).order(.user_data_32, .asc),
        any.order(.id, .desc).limit(2),
        any.order(.code, .asc).order(.timestamp, .desc).offset(1).limit(3),
        any.offset(5),
        any.offset(9),
        any.where(.ledger, .eq, 701).limit(1).offset(1),
    };
    inline for (cases, 0..) |case, n| {
        errdefer std.debug.print("lint read case {d} failed\n", .{n});
        var want: std.ArrayList(usize) = .empty;
        defer want.deinit(testing.allocator);
        var matched: [6]tb.Account = undefined;
        var len: usize = 0;
        for (s) |row| if (case.query.matches(row)) {
            matched[len] = row;
            len += 1;
        };
        std.mem.sort(tb.Account, matched[0..len], case.query.orderSlice(), zom.Query(tb.Account).lessThan);
        const start, const end = reads.window(len, case.query.offset, case.query.limit);
        for (matched[start..end]) |row| try want.append(testing.allocator, @intCast(row.id - tag));

        const rows = try case.toSlice(testing.allocator);
        defer testing.allocator.free(rows);
        try expectRows(&s, want.items, rows);
        const count = if (@TypeOf(case).mode == .fallback) try case.count(testing.allocator) else try case.count();
        try testing.expectEqual(want.items.len, count);
    }
}

const Balances = zom.Relation(schemas.AccountBalance, Gateway);

/// Two accounts with history and three transfers between them, created one
/// at a time so their timestamps go up in this order: 10 from a to b, 3
/// from b to a (code 2), 5 from a to b.
fn seedHistory(accounts: Accounts, transfers: Transfers) !struct { u128, u128, [3]tb.Transfer } {
    const base = freshIds();
    const history = tb.AccountFlags.bits(.{ .history = true });
    const a = base + 1;
    const b = base + 2;
    _ = try accounts.createMany(&.{
        .{ .id = a, .ledger = 700, .code = 10, .flags = history },
        .{ .id = b, .ledger = 700, .code = 10, .flags = history },
    }).commit();
    var stored: [3]tb.Transfer = undefined;
    const rows = [_]tb.Transfer{
        .{ .id = base + 10, .debit_account_id = a, .credit_account_id = b, .amount = 10, .ledger = 700, .code = 1 },
        .{ .id = base + 11, .debit_account_id = b, .credit_account_id = a, .amount = 3, .ledger = 700, .code = 2 },
        .{ .id = base + 12, .debit_account_id = a, .credit_account_id = b, .amount = 5, .ledger = 700, .code = 1 },
    };
    for (&stored, rows) |*s, row| s.* = try transfers.create(row).commit();
    return .{ a, b, stored };
}

fn expectTransfers(want: []const tb.Transfer, got: []const tb.Transfer) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqual(w, g);
}

test "combine(.transfers) and combine(.balances): an account's history" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const transfers = try Transfers.init(&gateway);
    const balances = try Balances.init(&gateway);
    const a, const b, const t = try seedHistory(accounts, transfers);
    const alloc = testing.allocator;

    // The transfers of `a`, as debit and as credit account: one lookup for
    // the account, one get_account_transfers.
    const WithTransfers = struct { id: u128, transfers: []const tb.Transfer };
    var before = gateway.requestCount();
    var history = try accounts.byPk(a).combine(.transfers, transfers).mapTo(WithTransfers, alloc);
    defer history.deinit();
    try testing.expectEqual(2, gateway.requestCount() - before);
    try testing.expectEqual(1, history.items.len);
    try testing.expectEqual(a, history.items[0].id);
    try expectTransfers(&t, history.items[0].transfers);

    // And its balances after each of them: one lookup, one get_account_balances.
    const WithBalances = struct { id: u128, balances: []const tb.AccountBalance };
    before = gateway.requestCount();
    var balanced = try accounts.byPk(a).combine(.balances, balances).mapTo(WithBalances, alloc);
    defer balanced.deinit();
    try testing.expectEqual(2, gateway.requestCount() - before);
    const rows = balanced.items[0].balances;
    try testing.expectEqual(3, rows.len);
    const debits = [_]u128{ 10, 10, 15 };
    const credits = [_]u128{ 0, 3, 3 };
    for (rows, t, debits, credits) |row, transfer, d, c_| {
        try testing.expectEqual(a, row.account_id);
        try testing.expectEqual(transfer.timestamp, row.timestamp);
        try testing.expectEqual(d, row.debits_posted);
        try testing.expectEqual(c_, row.credits_posted);
        try testing.expectEqual(0, row.debits_pending);
    }

    // The combined relation's filters and order: code is in the
    // AccountFilter, a timestamp desc order is its reversed flag, and
    // ledger (not in it) is checked on the rows.
    var coded = try accounts.byPk(a).combine(.transfers, transfers.where(.code, .eq, 1).where(.ledger, .eq, 700).order(.timestamp, .desc)).mapTo(WithTransfers, alloc);
    defer coded.deinit();
    try expectTransfers(&.{ t[2], t[0] }, coded.items[0].transfers);

    // Two accounts: every transfer is in both, each once per account.
    var both = try accounts.whereIn(.id, &[_]u128{ b, a }).combine(.transfers, transfers).mapTo(WithTransfers, alloc);
    defer both.deinit();
    try testing.expectEqual(2, both.items.len);
    for (both.items) |item| try expectTransfers(&t, item.transfers);

    // A limit pages each account's transfers, as for any combine: the
    // latest one of each account.
    var latest = try accounts.whereIn(.id, &[_]u128{ a, b }).combine(.transfers, transfers.order(.timestamp, .desc).limit(1)).mapTo(WithTransfers, alloc);
    defer latest.deinit();
    try testing.expectEqual(2, latest.items.len);
    for (latest.items) |item| try expectTransfers(t[2..3], item.transfers);
}

test "belongsTo into accounts is a lookup; hasMany by debit or credit account picks one side" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const transfers = try Transfers.init(&gateway);
    const a, const b, const t = try seedHistory(accounts, transfers);
    const alloc = testing.allocator;

    const WithDebit = struct { id: u128, debit_account: ?tb.Account };
    const before = gateway.requestCount();
    var paid = try transfers.whereIn(.id, &[_]u128{ t[0].id, t[1].id }).combine(.debit_account, accounts).mapTo(WithDebit, alloc);
    defer paid.deinit();
    // One lookup of the transfers, one of their two debit accounts.
    try testing.expectEqual(2, gateway.requestCount() - before);
    try testing.expectEqual(a, paid.items[0].debit_account.?.id);
    try testing.expectEqual(b, paid.items[1].debit_account.?.id);

    // A schema of the caller's own, over the same accounts, with a hasMany
    // on either side, and one on an indexed field.
    const Sided = zom.Schema(tb.Account, "sided_accounts", .id, .{
        .associations = struct {
            pub const debits = zom.hasMany(schemas.Transfer, .debit_account_id);
            pub const credits = zom.hasMany(schemas.Transfer, .credit_account_id);
            pub const tagged = zom.hasMany(schemas.Transfer, .user_data_128);
        },
    });
    const sided = try zom.Relation(Sided, Gateway).init(&gateway);
    const both = sided.whereIn(.id, &[_]u128{ a, b }).order(.timestamp, .asc);
    var debits = try both.combine(.debits, transfers).mapTo(struct { id: u128, debits: []const tb.Transfer }, alloc);
    defer debits.deinit();
    try expectTransfers(&.{ t[0], t[2] }, debits.items[0].debits);
    try expectTransfers(&.{t[1]}, debits.items[1].debits);
    var credits = try both.combine(.credits, transfers).mapTo(struct { id: u128, credits: []const tb.Transfer }, alloc);
    defer credits.deinit();
    try expectTransfers(&.{t[1]}, credits.items[0].credits);
    try expectTransfers(&.{ t[0], t[2] }, credits.items[1].credits);
    // One query_transfers per account: none of the seeded transfers has
    // user_data_128 = a or b.
    const reads_before = gateway.requestCount();
    var tagged = try both.combine(.tagged, transfers).mapTo(struct { id: u128, tagged: []const tb.Transfer }, alloc);
    defer tagged.deinit();
    try testing.expectEqual(3, gateway.requestCount() - reads_before);
    try testing.expectEqual(0, tagged.items[0].tagged.len + tagged.items[1].tagged.len);
}

test "AccountBalance: read by account_id, ordered and limited; without one, AccountIdRequired" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
    const accounts = try Accounts.init(&gateway);
    const transfers = try Transfers.init(&gateway);
    const balances = try Balances.init(&gateway);
    const a, const b, const t = try seedHistory(accounts, transfers);
    const alloc = testing.allocator;

    const latest = (try balances.where(.account_id, .eq, b).order(.timestamp, .desc).first(alloc)).?;
    try testing.expectEqual(t[2].timestamp, latest.timestamp);
    try testing.expectEqual(3, latest.debits_posted);
    try testing.expectEqual(15, latest.credits_posted);

    try testing.expectEqual(3, try balances.where(.account_id, .eq, a).count());
    try testing.expectEqual(1, try balances.where(.account_id, .eq, a).where(.timestamp, .gt, t[1].timestamp).count());
    // Two accounts, newest first across both: sorted in memory.
    const newest = try balances.whereIn(.account_id, &[_]u128{ a, b }).order(.timestamp, .desc).limit(2).toSlice(alloc);
    defer alloc.free(newest);
    try testing.expectEqual(2, newest.len);
    try testing.expectEqual(t[2].timestamp, newest[0].timestamp);
    try testing.expectEqual(t[2].timestamp, newest[1].timestamp);

    try testing.expectError(error.AccountIdRequired, balances.byPk(t[0].timestamp).toSlice(alloc));
}
