//! The TigerBeetle gateway: one `tb_client` (the C client, linked as a
//! static library) and a dataset for each of the two fixed schemas,
//! `zom_tigerbeetle.Account` and `zom_tigerbeetle.Transfer`.
//!
//! TigerBeetle records are immutable, so the datasets have no `update` and
//! no `delete`: `relation.update()` and `relation.delete()` don't compile.
//! Inserts (`create_accounts` / `create_transfers`) come in #55, and reads
//! (`lookup_*` / `query_*`) in #56; until then `read` and `count` return
//! `error.Unimplemented`.
//!
//! The client works by callback: `tb_client_submit` queues a packet, and
//! the client's own thread calls back when the reply arrives. `submit`
//! wraps that in a blocking call, waiting on a `std.Io.Event`.

const std = @import("std");
const zom = @import("zom");
const tb = @import("tb.zig");
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
    };

    /// What every zom-tigerbeetle call can fail with. The first is one of
    /// zom's shared names (`zom.Error`).
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
        /// The client rejected a request zom built (`TB_PACKET_TOO_MUCH_DATA`,
        /// `INVALID_OPERATION`, `INVALID_DATA_SIZE`), or `tb_client_init`
        /// failed for no stated reason. A bug in zom-tigerbeetle.
        Unexpected,
        /// Not written yet; see the file comment.
        Unimplemented,
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
        accounts: Dataset(schemas.Account),
        transfers: Dataset(schemas.Transfer),
    };

    /// Starts the client. It connects in the background: an unreachable
    /// cluster shows up on the first request, not here.
    pub fn init(allocator: Allocator, config: Config) Error!Gateway {
        const shared = try allocator.create(Shared);
        errdefer allocator.destroy(shared);
        shared.* = .{
            .client = undefined,
            .io = config.io,
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

    /// Sends one request and blocks until its reply. `events` is the
    /// request body (a slice of `tb.Account`s, ids, filters...), and the
    /// reply is copied into `results`, which must be big enough for any
    /// reply to `events` (the caller knows the bound per operation).
    /// Returns the reply's length in bytes.
    fn submit(self: *Gateway, operation: c.TB_OPERATION, events: []const u8, results: []u8) Error!usize {
        var request: Request = .{ .results = results };
        var packet = std.mem.zeroes(c.tb_packet_t);
        packet.user_data = &request;
        packet.data = @constCast(events.ptr);
        packet.data_size = std.math.cast(u32, events.len) orelse return error.Unexpected;
        packet.operation = @intCast(operation);

        // Only an uninitialized or closed client is refused, and a
        // gateway's client is neither until `deinit`.
        const status = c.tb_client_submit(&self.shared.client, &packet);
        std.debug.assert(status == c.TB_CLIENT_OK);
        // `packet` and `request` are on this stack, so the reply must be
        // waited for even when the caller's task is cancelled.
        request.done.waitUncancelable(self.shared.io);

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

    /// One `submit` in flight, pointed to by its packet's `user_data`.
    const Request = struct {
        results: []u8,
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
            std.debug.assert(size <= request.results.len);
            @memcpy(request.results[0..size], result[0..size]);
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
    return struct {
        const Self = @This();

        shared: *Gateway.Shared,

        /// `lookup_*` / `query_*`, in #56.
        pub fn read(self: *Self, query: Q, allocator: Allocator) Gateway.Error![]T {
            _ = self;
            _ = query;
            _ = allocator;
            return error.Unimplemented;
        }

        /// In #56.
        pub fn count(self: *Self, query: Q) Gateway.Error!usize {
            _ = self;
            _ = query;
            return error.Unimplemented;
        }
    };
}

const testing = std.testing;

/// The live test runs against `ZOM_TB_ADDRESSES` (e.g. `3000`), on cluster
/// 0, and is skipped when it isn't set. A dev cluster:
///
///     tigerbeetle format --cluster=0 --replica=0 --replica-count=1 --development 0_0.tigerbeetle
///     tigerbeetle start --addresses=3000 --development 0_0.tigerbeetle
fn testAddresses(allocator: Allocator) ![]u8 {
    return testing.environ.getAlloc(allocator, "ZOM_TB_ADDRESSES") catch |err| switch (err) {
        error.EnvironmentVariableMissing => error.SkipZigTest,
        else => |e| e,
    };
}

test "init connects: a lookup of an unknown id round-trips with no result" {
    const addresses = try testAddresses(testing.allocator);
    defer testing.allocator.free(addresses);
    var gateway = try Gateway.init(testing.allocator, .{ .io = testing.io, .cluster_id = 0, .addresses = addresses });
    defer gateway.deinit();

    // Above maxInt(u64), and not an id anything else creates.
    const ids = [_]u128{std.math.maxInt(u128) - 54};
    var results: [@sizeOf(tb.Account)]u8 align(16) = undefined;
    const len = try gateway.submit(c.TB_OPERATION_LOOKUP_ACCOUNTS, std.mem.sliceAsBytes(&ids), &results);
    try testing.expectEqual(0, len);
}
