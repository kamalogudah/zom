// expect: zom.file: format 'file_format_missing_decls.BadFormat' does not satisfy the format contract:
// expect: - missing `pub const extension: []const u8 (".csv")`
// expect: - missing `pub fn dump(comptime S: type, zom.file.DumpContext(Format, S), *std.Io.Writer) WriteError!void`
// expect: - `layout` must be a zom.file.Layout, found `@EnumLiteral()`
// expect: - `Config` has no field `max_file_bytes: usize`
// expect: - `Config.path` must be `[]const u8`, found `[:0]const u8`
const std = @import("std");
const zom = @import("zom");

const BadFormat = struct {
    pub const name = "bad";
    pub const layout = .one_per_file;
    pub const Config = struct { io: std.Io, path: [:0]const u8, dir: std.Io.Dir };
    pub const WriteError = error{};

    pub fn load(comptime S: type, _: anytype, _: *zom.memory.Store(S)) !void {}
};

comptime {
    _ = zom.file.Gateway(BadFormat, .read_only);
}
