//! The field-by-field mapper behind `zom.Mapper`. Internal: not exported
//! from root.zig.
//!
//! `skip` names `Dst` fields the mapper leaves undefined. Only `combine`
//! uses it, for the association field, which has no source attribute and
//! which it fills right after `call`. A public mapper always sets every
//! field, so `zom.Mapper` is this with `skip` empty.

const std = @import("std");
const Options = @import("mapper.zig").Options;

pub fn FieldMapper(
    comptime Src: type,
    comptime Dst: type,
    comptime opts: Options,
    comptime skip: []const []const u8,
) type {
    return struct {
        pub const Input = Src;
        pub const Output = Dst;
        pub const options = opts;

        /// The `Src` fields copied into `Dst`, e.g. to know which strings
        /// the output now shares with the input. A skipped field copies
        /// nothing, so a `Src` string of the same name is not listed: for
        /// caller-owned strings it stays the reader's to free.
        pub const sources: []const []const u8 = blk: {
            var names: []const []const u8 = &.{};
            for (@typeInfo(Dst).@"struct".fields) |f| {
                if (skipped(f.name)) continue;
                const src_name = sourceName(f.name);
                if (@hasField(Src, src_name)) names = names ++ .{src_name};
            }
            break :blk names;
        };

        fn skipped(comptime name: []const u8) bool {
            for (skip) |s| {
                if (std.mem.eql(u8, s, name)) return true;
            }
            return false;
        }

        fn sourceName(comptime name: []const u8) []const u8 {
            for (opts.renames) |r| {
                if (std.mem.eql(u8, r.to, name)) return r.from;
            }
            return name;
        }

        pub fn call(src: Src) Dst {
            var dst: Dst = undefined;
            inline for (@typeInfo(Dst).@"struct".fields) |f| {
                const src_name = comptime sourceName(f.name);
                if (comptime skipped(f.name)) {
                    // Left for the caller.
                } else if (comptime @hasField(Src, src_name)) {
                    @field(dst, f.name) = @field(src, src_name);
                } else if (comptime f.defaultValue() != null) {
                    @field(dst, f.name) = comptime f.defaultValue().?;
                } else {
                    @compileError("zom.Mapper: " ++ @typeName(Dst) ++ "." ++ f.name ++
                        " has no source attribute `" ++ src_name ++ "` and no default");
                }
            }
            return dst;
        }

        /// Caller owns the returned slice.
        pub fn many(allocator: std.mem.Allocator, srcs: []const Src) ![]Dst {
            const out = try allocator.alloc(Dst, srcs.len);
            for (srcs, out) |s, *d| d.* = call(s);
            return out;
        }
    };
}
