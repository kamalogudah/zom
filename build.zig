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
/// say "this must not compile", so each case must exit 1 with its `// expect:`
/// text (first line of the file) somewhere in stderr.
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
        const first_line = source[0 .. std.mem.indexOfScalar(u8, source, '\n') orelse source.len];
        if (!std.mem.startsWith(u8, first_line, expect_prefix))
            std.debug.panic("{s}/{s}: first line must be `{s}<error text>`", .{ compile_errors_dir, entry.name, expect_prefix });
        const expected = std.mem.trimEnd(u8, first_line[expect_prefix.len..], " \r");

        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-fno-emit-bin", "--dep", "zom" });
        run.setName(b.fmt("compile-error {s}", .{entry.name}));
        run.addPrefixedFileArg("-Mroot=", b.path(b.fmt("{s}/{s}", .{ compile_errors_dir, entry.name })));
        run.addPrefixedFileArg("-Mzom=", b.path("src/root.zig"));
        run.expectExitCode(1);
        run.expectStdErrMatch(expected);
        // Only the case file is tracked as an input; always rerun so edits under src/ are seen.
        run.has_side_effects = true;
        step.dependOn(&run.step);
    }
}
