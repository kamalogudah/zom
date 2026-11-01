//! zom-pg-infer: writes Zig schema structs for the tables of a Postgres
//! schema. `Gateway.introspect` reads them, `zom_sql.infer.render` writes
//! them. Applications run it through `addInferStep` in zom-pg's build.zig.

const std = @import("std");
const zom_sql = @import("zom_sql");
const zom_pg = @import("zom_pg");

// zom-pg logs every server error at debug level; the messages below say
// what went wrong instead.
pub const std_options: std.Options = .{ .log_level = .warn };

const usage =
    \\usage: zom-pg-infer [options]
    \\
    \\Writes a Zig struct and zom.Schema for every table of a Postgres schema.
    \\
    \\  --url URL         postgres://user:pass@host:port/db
    \\  --url-env NAME    read the URL from environment variable NAME
    \\                    (default DATABASE_URL, when --url is not given)
    \\  --schema NAME     the Postgres schema to read (default public)
    \\  --zom-import NAME what the generated file @imports zom as (default zom)
    \\  --out PATH        the file to write (default stdout)
    \\  --quiet           don't say what was written
    \\  -h, --help        print this and exit
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var url_arg: []const u8 = "";
    var url_env: []const u8 = "DATABASE_URL";
    var schema: []const u8 = "public";
    var zom_import: []const u8 = "zom";
    var out_arg: []const u8 = "";
    var quiet = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try std.Io.File.stdout().writeStreamingAll(io, usage);
            return;
        }
        if (std.mem.eql(u8, arg, "--quiet")) {
            quiet = true;
            continue;
        }
        const slot: *[]const u8 = if (std.mem.eql(u8, arg, "--url"))
            &url_arg
        else if (std.mem.eql(u8, arg, "--url-env"))
            &url_env
        else if (std.mem.eql(u8, arg, "--schema"))
            &schema
        else if (std.mem.eql(u8, arg, "--zom-import"))
            &zom_import
        else if (std.mem.eql(u8, arg, "--out"))
            &out_arg
        else
            fatal("unknown option {s}\n\n{s}", .{ arg, usage });
        i += 1;
        if (i == args.len) fatal("{s} needs a value\n\n{s}", .{ arg, usage });
        slot.* = args[i];
    }
    const url: ?[]const u8 = if (url_arg.len == 0) null else url_arg;
    const out: ?[]const u8 = if (out_arg.len == 0) null else out_arg;

    const conn_url = url orelse init.environ_map.get(url_env) orelse
        fatal("no database: pass --url, or set {s}", .{url_env});

    var gateway = zom_pg.Gateway.init(gpa, .{ .io = io, .url = conn_url, .pool_size = 1 }) catch |err| switch (err) {
        // The URL may hold a password, so it isn't echoed.
        error.InvalidUrl => fatal("the database URL is not a valid postgres:// URL", .{}),
        error.ConnectionFailed => fatal("can't connect to the database{f}", .{serverMessage()}),
        else => |e| return e,
    };
    defer gateway.deinit();

    var found = gateway.introspect(gpa, schema) catch |err| switch (err) {
        error.SchemaNotFound => fatal("the database has no schema \"{f}\"", .{std.zig.fmtString(schema)}),
        error.Database, error.ConnectionFailed => fatal("reading the catalog failed{f}", .{serverMessage()}),
        else => |e| return e,
    };
    defer found.deinit();

    const source = zom_sql.infer.render(gpa, found.catalog, .{ .zom_import = zom_import }) catch |err| switch (err) {
        error.NameCollision => {
            const c = (try zom_sql.infer.findCollision(gpa, found.catalog)).?;
            fatal("{f}; rename one of them", .{c});
        },
        else => |e| return e,
    };
    defer gpa.free(source);

    const path = out orelse return std.Io.File.stdout().writeStreamingAll(io, source);
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| try cwd.createDirPath(io, dir);
    cwd.writeFile(io, .{ .sub_path = path, .data = source }) catch |err|
        fatal("can't write {s}: {t}", .{ path, err });

    if (!quiet) std.debug.print("zom-pg-infer: wrote {d} tables from schema \"{f}\" to {s}\n", .{ found.catalog.tables.len, std.zig.fmtString(schema), path });
}

/// `: <message>` with the server's last error, or nothing.
fn serverMessage() std.fmt.Alt(void, struct {
    fn f(_: void, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (zom_pg.Gateway.lastError()) |e| try w.print(": {s}", .{e.message});
    }
}.f) {
    return .{ .data = {} };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zom-pg-infer: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
