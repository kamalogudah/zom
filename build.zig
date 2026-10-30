const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zom", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    // README code blocks, compiled against the public module like a user would.
    const readme = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/readme.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zom", .module = mod }},
    }) });
    const run_readme = b.addRunArtifact(readme);

    const compile_errors = b.step("compile-errors", "Check that tests/compile_errors/*.zig fail with the expected message");
    addCompileErrorCases(b, compile_errors);

    const test_step = b.step("test", "Run zom.zig tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_readme.step);
    test_step.dependOn(compile_errors);
}

const compile_errors_dir = "tests/compile_errors";
const expect_prefix = "// expect: ";

/// One `zig build-obj` per case, with zom as a module import. `zig test` can't
/// say "this must not compile", so each case must exit 1 with the text of every
/// leading `// expect:` line (at least the first line of the file) somewhere in
/// stderr. Several lines let one case check every line of a multi-line error.
fn addCompileErrorCases(b: *std.Build, step: *std.Build.Step) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, compile_errors_dir, .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open {s}: {t}", .{ compile_errors_dir, err });
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("unable to list {s}: {t}", .{ compile_errors_dir, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const source = dir.readFileAlloc(io, entry.name, b.allocator, .limited(64 * 1024)) catch |err|
            std.debug.panic("unable to read {s}/{s}: {t}", .{ compile_errors_dir, entry.name, err });
        if (!std.mem.startsWith(u8, source, expect_prefix))
            std.debug.panic("{s}/{s}: first line must be `{s}<error text>`", .{ compile_errors_dir, entry.name, expect_prefix });

        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-fno-emit-bin", "--dep", "zom" });
        run.setName(b.fmt("compile-error {s}", .{entry.name}));
        run.addPrefixedFileArg("-Mroot=", b.path(b.fmt("{s}/{s}", .{ compile_errors_dir, entry.name })));
        run.addPrefixedFileArg("-Mzom=", b.path("src/root.zig"));
        run.expectExitCode(1);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, expect_prefix)) break;
            run.expectStdErrMatch(std.mem.trimEnd(u8, line[expect_prefix.len..], " \r"));
        }
        // Only the case file is tracked as an input; always rerun so edits under src/ are seen.
        run.has_side_effects = true;
        step.dependOn(&run.step);
    }
}
