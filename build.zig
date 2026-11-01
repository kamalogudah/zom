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

    const test_adapters = b.step("test-adapters", "Run each adapters/<name> package's tests");
    addAdapterTests(b, test_adapters, optimize);

    const test_examples = b.step("test-examples", "Build and run each examples/<name> package, checking its output");
    addExampleTests(b, test_examples, optimize);

    const test_step = b.step("test", "Run zom.zig tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_readme.step);
    test_step.dependOn(compile_errors);
    test_step.dependOn(test_adapters);
    test_step.dependOn(test_examples);
}

/// The packages under `adapters/`. Each has its own build.zig.zon depending
/// on zom through `.path = "../.."`. They are listed rather than found by
/// scanning, because `adapters/` is not in zom's `.paths`: a project that
/// fetches zom doesn't get it, and these steps only run from a checkout.
const adapter_dirs = [_][]const u8{ "csv", "yaml" };

/// Runs `zig build test` inside each adapter's directory, as a separate
/// build, so the adapter resolves zom the same way an application would.
fn addAdapterTests(b: *std.Build, step: *std.Build.Step, optimize: std.builtin.OptimizeMode) void {
    for (adapter_dirs) |name| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", b.fmt("-Doptimize={t}", .{optimize}) });
        run.setName(b.fmt("test adapters/{s}", .{name}));
        run.setCwd(b.path(b.fmt("adapters/{s}", .{name})));
        // The adapter's build has its own cache; always hand it control.
        run.has_side_effects = true;
        step.dependOn(&run.step);
    }
}

/// The example programs under `examples/`, each its own package depending
/// on zom and the adapters it uses by path. Like the adapters, they are
/// listed, and only exist in a checkout.
const example_dirs = [_][]const u8{"csv_users"};

/// Runs `zig build test` inside each example's directory: it builds the
/// program, runs it, and compares its stdout with the expected output.
fn addExampleTests(b: *std.Build, step: *std.Build.Step, optimize: std.builtin.OptimizeMode) void {
    for (example_dirs) |name| {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", b.fmt("-Doptimize={t}", .{optimize}) });
        run.setName(b.fmt("test examples/{s}", .{name}));
        run.setCwd(b.path(b.fmt("examples/{s}", .{name})));
        run.has_side_effects = true;
        step.dependOn(&run.step);
    }
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
