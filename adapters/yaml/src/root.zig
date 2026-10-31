//! zom-yaml = rom's `rom-yaml`: a gateway over one YAML file holding every
//! dataset, or a directory of `<name>.yaml` files, each dataset held in a
//! `zom.memory.Store(S)`.
//!
//! `yaml` parses the supported subset of YAML (dataset names mapped to
//! sequences of flat records, or one bare sequence) into records whose
//! values are scalar text, and writes scalars back. See `yaml.zig` for
//! exactly what is accepted. `Gateway` is read-only; `WritableGateway` adds
//! writes and an atomic `sync()`. Both are `zom.file.Gateway` over
//! `Format`, the same shell as zom-csv. See `gateway.zig`.

pub const yaml = @import("yaml.zig");

const gateway = @import("gateway.zig");
pub const Gateway = gateway.Gateway;
pub const WritableGateway = gateway.WritableGateway;
pub const Format = gateway.Format;
pub const Config = gateway.Config;
pub const SyncError = gateway.SyncError;
pub const WriteError = gateway.WriteError;
pub const Diagnostic = gateway.Diagnostic;
pub const UnknownKeys = gateway.UnknownKeys;
pub const writeRecords = gateway.writeRecords;
pub const writeDataset = gateway.writeDataset;

test {
    _ = yaml;
    _ = gateway;
    _ = @import("yaml_test.zig");
    _ = @import("gateway_test.zig");
}
