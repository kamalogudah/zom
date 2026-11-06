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
const c = tb.c;

const Allocator = std.mem.Allocator;
const log = std.log.scoped(.zom_tigerbeetle);

pub const Gateway = struct {
    pub const adapter_name = "tigerbeetle";

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

    /// One of zom-tigerbeetle's two datasets. `S` must be a `zom.Schema`
    /// of `tb.Account` or `tb.Transfer` keyed by `.id`, such as
    /// `zom_tigerbeetle.Account`; the dataset name is not used, since
    /// TigerBeetle's are fixed.
    pub fn Dataset(comptime S: type) type {
        comptime checkSchema(S);
        return TbDataset(S);
    }

    /// The dataset for `S`. The pointer stays valid until `deinit`.
    pub fn dataset(self: *Gateway, comptime S: type) error{}!*Dataset(S) {
        return if (S.Tuple == tb.Account) &self.shared.accounts else &self.shared.transfers;
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
    if (S.Tuple != tb.Account and S.Tuple != tb.Transfer)
        @compileError("zom-tigerbeetle: TigerBeetle's schemas are fixed; schema \"" ++ S.name ++ "\" must be a zom.Schema of " ++
            "zom_tigerbeetle.tb.Account or .Transfer (or use zom_tigerbeetle.Account / .Transfer), found `" ++ @typeName(S.Tuple) ++ "`");
    if (S.primary_key != .id)
        @compileError("zom-tigerbeetle: schema \"" ++ S.name ++ "\" must have `.id` as its primary key, found `." ++ @tagName(S.primary_key) ++ "`");
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

        const Reply = if (is_account) c.tb_create_account_result_t else c.tb_create_transfer_result_t;
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
            var rows: Collect = .{ .allocator = allocator };
            errdefer rows.items.deinit(allocator);
            // Sorting needs every match; otherwise the first offset + limit do.
            try self.scan(&query, p, if (p.sort) null else wanted(&query), &rows);

            const items = rows.items.items;
            if (p.sort) std.mem.sort(T, items, query.orderSlice(), Q.lessThan);
            const start, const end = reads.window(items.len, query.offset, query.limit);
            std.mem.copyForwards(T, items[0 .. end - start], items[start..end]);
            rows.items.shrinkRetainingCapacity(end - start);
            return rows.items.toOwnedSlice(allocator);
        }

        /// How many rows `read` would return. TigerBeetle has no count, so
        /// this reads them, page by page, and keeps none: up to `offset +
        /// limit` rows, or every match, at most `Config.scan_max`.
        pub fn count(self: *Self, query: Q) Gateway.Error!usize {
            var counter: Counter = .{};
            // The order changes which rows, not how many.
            try self.scan(&query, reads.plan(T, &query), wanted(&query), &counter);
            const start, const end = reads.window(counter.n, query.offset, query.limit);
            return end - start;
        }

        /// The matches a read needs, null for all: `offset + limit`.
        fn wanted(query: *const Q) ?usize {
            const l = query.limit orelse return null;
            if (l == 0) return 0;
            return std.math.add(usize, l, query.offset) catch null;
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
                    const rows = try self.submitRead(lookup_operation, std.mem.sliceAsBytes(ids.slice()), reply[0..ids.len]);
                    var matched: usize = 0;
                    for (rows) |row| {
                        if (!query.matches(row)) continue;
                        try sink.add(row);
                        matched += 1;
                        if (matched == want) return;
                    }
                },
                .query => |filter| try self.scanQuery(query, filter, want, sink),
            }
        }

        /// `query_*` from `base`, a page at a time: each page starts past
        /// the last timestamp of the one before (`reads.advance`).
        fn scanQuery(self: *Self, query: *const Q, base: c.tb_query_filter_t, want: ?usize, sink: anytype) Gateway.Error!void {
            const shared = self.shared;
            const page_max: u32 = @intCast(@min(want orelse reads.query_max, reads.query_max, shared.scan_max));
            const page = try shared.allocator.alloc(T, page_max);
            defer shared.allocator.free(page);

            var filter = base;
            var matched: usize = 0;
            var fetched: u64 = 0;
            // Once a row is filtered out here, pages may need more rows
            // than the matches still missing.
            var dropped = false;
            // Every page but the last is full, so `fetched` grows by at
            // least one per page, and `scan_max` bounds the loop. A page is
            // never bigger than what is left of `scan_max`, so a read that
            // stops there fetched exactly `scan_max` rows.
            while (fetched < shared.scan_max) {
                const missing: u64 = if (want) |w| (if (dropped) page_max else w - matched) else page_max;
                const asked: u32 = @intCast(@min(page_max, missing, shared.scan_max - fetched));
                std.debug.assert(asked > 0);
                filter.limit = asked;
                const rows = try self.submitRead(query_operation, std.mem.asBytes(&filter), page[0..asked]);
                fetched += rows.len;
                for (rows) |row| {
                    if (!query.matches(row)) {
                        dropped = true;
                        continue;
                    }
                    try sink.add(row);
                    matched += 1;
                    if (matched == want) return;
                }
                // A short page is the last (see `reads.query_max`).
                if (rows.len < asked) return;
                if (!reads.advance(&filter, rows[rows.len - 1].timestamp)) return;
            }
            return error.ScanLimitExceeded;
        }

        /// One `lookup_*` or `query_*` request; the reply is records.
        fn submitRead(self: *Self, op: c.TB_OPERATION, events: []const u8, reply: []T) Gateway.Error![]T {
            const len = self.shared.submit(op, events, std.mem.sliceAsBytes(reply)) catch |err| switch (err) {
                // One filter, or at most 64 ids, is far below any cluster's
                // smallest request (see `reads.lookup_max`).
                error.TooMuchData => return error.Unexpected,
                else => |e| return e,
            };
            if (len % @sizeOf(T) != 0) {
                log.debug("a read reply of {d} bytes isn't whole records", .{len});
                return error.Unexpected;
            }
            return reply[0 .. len / @sizeOf(T)];
        }

        const Collect = struct {
            allocator: Allocator,
            items: std.ArrayList(T) = .empty,

            fn add(self: *Collect, row: T) Allocator.Error!void {
                try self.items.append(self.allocator, row);
            }
        };

        const Counter = struct {
            n: usize = 0,

            fn add(self: *Counter, _: T) error{}!void {
                self.n += 1;
            }
        };

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
test "lint read checks: every query agrees with the same one in memory" {
    var gateway = try testGateway(.{});
    defer gateway.deinit();
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
