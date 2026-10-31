//! zom-yaml = rom's `rom-yaml`: datasets read from YAML files.
//!
//! `yaml` parses the supported subset of YAML (dataset names mapped to
//! sequences of flat records, or one bare sequence) into records whose
//! values are scalar text, for `zom.codec` to decode. See `yaml.zig` for
//! exactly what is accepted. The gateway over `zom.memory.Store` comes next.

pub const yaml = @import("yaml.zig");

test {
    _ = yaml;
    _ = @import("yaml_test.zig");
}
