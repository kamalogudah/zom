//! zom-csv = rom's `rom-csv`: a gateway over a CSV file or a directory of
//! them, one dataset per file, each held in a `zom.memory.Store(S)`.
//!
//! `csv` is the RFC 4180 reader and writer. `Gateway` is read-only;
//! `WritableGateway` adds writes and an atomic `sync()`. See `gateway.zig`
//! for how files are found, checked, loaded and written back.

const std = @import("std");

pub const csv = @import("csv.zig");

const gateway = @import("gateway.zig");
pub const Gateway = gateway.Gateway;
pub const WritableGateway = gateway.WritableGateway;
pub const Config = gateway.Config;
pub const SyncError = gateway.SyncError;
pub const WriteError = gateway.WriteError;
pub const Diagnostic = gateway.Diagnostic;
pub const UnknownColumns = gateway.UnknownColumns;
pub const WriteOptions = gateway.WriteOptions;
pub const writeTable = gateway.writeTable;

test {
    _ = csv;
    _ = gateway;
    _ = @import("gateway_test.zig");
}
