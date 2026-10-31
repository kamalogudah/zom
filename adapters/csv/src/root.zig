//! zom-csv = rom's `rom-csv`: a gateway over a CSV file or a directory of
//! them, one dataset per file, each held in a `zom.memory.Store(S)`.
//!
//! `csv` is the RFC 4180 reader and writer. `Gateway` is read-only; see
//! `gateway.zig` for how files are found, checked and loaded.

const std = @import("std");

pub const csv = @import("csv.zig");

const gateway = @import("gateway.zig");
pub const Gateway = gateway.Gateway;
pub const Diagnostic = gateway.Diagnostic;
pub const UnknownColumns = gateway.UnknownColumns;
pub const WriteOptions = gateway.WriteOptions;
pub const writeTable = gateway.writeTable;

test {
    _ = csv;
    _ = @import("gateway_test.zig");
}
