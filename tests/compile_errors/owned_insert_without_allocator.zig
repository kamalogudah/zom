// expect: - `strings` is `.caller`, so `insert` must be `fn (*Self, Tuple, std.mem.Allocator) !Tuple`
const zom = @import("zom");
const fakes = @import("support/fakes.zig");

comptime {
    _ = zom.Adapter(fakes.OwnedNoAllocGateway).Dataset(fakes.ItemSchema);
}
