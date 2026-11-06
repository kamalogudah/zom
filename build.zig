const std = @import("std");

/// zom is one package that exports several modules: the core, `zom`, and one
/// module per adapter (`zom_csv`, `zom_yaml`, `zom_sql`, `zom_pg`). An
/// application depends on the package once and picks the modules it uses:
///
///     const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
///     const zom = dep.module("zom");
///     const zom_csv = dep.module("zom_csv");
///
/// zom-pg needs pg.zig, a lazy dependency, so it only exists when asked for
/// with `.pg = true`: an application that doesn't use Postgres never fetches
/// pg.zig. The adapters' code lives under `adapters/<name>/src` and imports
/// zom only through its public module, so an adapter can still move to a
/// repo of its own later without code changes (see plan.md, section 3.2).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // On by default in a checkout of zom itself (the root package, whose
    // pkg_hash is empty), so `zig build test` covers zom-pg; off by default
    // when zom is someone else's dependency.
    const with_pg = b.option(bool, "pg", "Build the zom_pg module (fetches pg.zig)") orelse (b.pkg_hash.len == 0);

    // Turns deprecated declarations (zom.combineMany) into compile errors,
    // to find the calls left before they are removed.
    const no_deprecated = b.option(bool, "no-deprecated", "Make uses of deprecated zom declarations compile errors") orelse false;

    const mod = b.addModule("zom", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", buildOptions(b, no_deprecated));

    const test_step = b.step("test", "Run zom.zig tests");
    const test_adapters = b.step("test-adapters", "Run the tests of every adapter module");

    const tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // README code blocks, compiled against the public module like a user would.
    const readme = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/readme.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zom", .module = mod }},
    }) });
    test_step.dependOn(&b.addRunArtifact(readme).step);

    const compile_errors = b.step("compile-errors", "Check that tests/compile_errors/*.zig fail with the expected message");
    addCompileErrorCases(b, compile_errors);
    test_step.dependOn(compile_errors);

    // The adapters with no dependency beyond zom (and each other).
    _ = addAdapter(b, test_adapters, "csv", &.{.{ .name = "zom", .module = mod }}, target, optimize);
    _ = addAdapter(b, test_adapters, "yaml", &.{.{ .name = "zom", .module = mod }}, target, optimize);
    const zom_sql = addAdapter(b, test_adapters, "sql", &.{.{ .name = "zom", .module = mod }}, target, optimize);

    if (with_pg) {
        if (b.lazyDependency("pg", .{ .target = target, .optimize = optimize })) |pg_dep| {
            addPg(b, test_adapters, mod, zom_sql.module, pg_dep.module("pg"), target, optimize);
        }
    } else {
        const fail = b.addFail("zom-pg is off: pass -Dpg=true (or `.pg = true` to b.dependency)");
        b.step("test-pg", "Run zom-pg's tests (its database tests need ZOM_PG_URL)").dependOn(&fail.step);
    }
    test_step.dependOn(test_adapters);

    const test_examples = b.step("test-examples", "Build and run each examples/<name> package, checking its output");
    addExampleTests(b, test_examples, optimize);
    test_step.dependOn(test_examples);
}

const Adapter = struct {
    module: *std.Build.Module,
    run_tests: *std.Build.Step.Run,
};

/// Exports `adapters/<name>/src/root.zig` as the module `zom_<name>` and adds
/// its tests to `step`.
fn addAdapter(
    b: *std.Build,
    step: *std.Build.Step,
    comptime name: []const u8,
    imports: []const std.Build.Module.Import,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) Adapter {
    const module = b.addModule("zom_" ++ name, .{
        .root_source_file = b.path("adapters/" ++ name ++ "/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    });
    const tests = b.addTest(.{ .name = "zom_" ++ name, .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    run_tests.setName("test zom_" ++ name);
    step.dependOn(&run_tests.step);
    return .{ .module = module, .run_tests = run_tests };
}

/// The `zom_pg` module, its tests, the `test-pg` step, and the `zom-pg-infer`
/// executable that `addInferStep` runs.
fn addPg(
    b: *std.Build,
    test_adapters: *std.Build.Step,
    zom: *std.Build.Module,
    zom_sql: *std.Build.Module,
    pg: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const adapter = addAdapter(b, test_adapters, "pg", &.{
        .{ .name = "zom", .module = zom },
        .{ .name = "zom_sql", .module = zom_sql },
        .{ .name = "pg", .module = pg },
    }, target, optimize);
    // The database tests read ZOM_PG_URL, which the cache can't see; without
    // it they are skipped.
    adapter.run_tests.has_side_effects = true;
    b.step("test-pg", "Run zom-pg's tests (its database tests need ZOM_PG_URL)").dependOn(&adapter.run_tests.step);

    const infer_exe = b.addExecutable(.{
        .name = "zom-pg-infer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("adapters/pg/src/infer_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zom_sql", .module = zom_sql },
                .{ .name = "zom_pg", .module = adapter.module },
            },
        }),
    });
    // Installed so that `addInferStep` can find it with `Dependency.artifact`.
    b.installArtifact(infer_exe);
    test_adapters.dependOn(&infer_exe.step);

    const run_infer = b.addRunArtifact(infer_exe);
    if (b.args) |args| run_infer.addArgs(args);
    b.step("infer", "Run zom-pg-infer (pass its options after --)").dependOn(&run_infer.step);
}

/// Options for `addInferStep`.
pub const InferOptions = struct {
    /// The source file to write, relative to the application's build
    /// root, e.g. "src/schemas.zig". Null to only produce `Infer.output`.
    out: ?[]const u8,
    /// The Postgres schema whose tables become structs.
    schema: []const u8 = "public",
    /// The environment variable holding the database URL, read when the
    /// step runs. Prefer this to `url`, so no password ends up in build.zig.
    url_env: []const u8 = "DATABASE_URL",
    /// The database URL itself; overrides `url_env`.
    url: ?[]const u8 = null,
    /// The name the application imports zom by.
    zom_import: []const u8 = "zom",
    /// The top-level step to add; null to add none and use `Infer.step`.
    step_name: ?[]const u8 = "infer",
    step_description: []const u8 = "Regenerate the schema structs from the database",
};

pub const Infer = struct {
    /// Runs zom-pg-infer and, with `out` set, writes the file.
    step: *std.Build.Step,
    /// The generated file in the cache. Using it as a module's source makes
    /// every build query the database (the step has side effects); the
    /// usual setup is to commit `out` and run the step when the tables
    /// change.
    output: std.Build.LazyPath,
};

/// Adds a step that reads a live database with zom-pg-infer and writes a
/// Zig struct and `zom.Schema` for each table, from an application's
/// build.zig:
///
///     const zom_build = @import("zom");
///     _ = zom_build.addInferStep(b, .{ .out = "src/schemas.zig" });
///
/// Then `DATABASE_URL=postgres://... zig build infer`. This turns zom-pg on
/// for zom's host build, so it fetches pg.zig even if the application's own
/// `b.dependency("zom", ...)` leaves `.pg` off.
pub fn addInferStep(b: *std.Build, options: InferOptions) Infer {
    const dep = b.dependencyFromBuildZig(@This(), .{ .target = b.graph.host, .pg = true });
    const run = b.addRunArtifact(dep.artifact("zom-pg-infer"));
    run.setName(b.fmt("zom-pg-infer (schema {s})", .{options.schema}));
    // The database is input the cache can't see.
    run.has_side_effects = true;
    if (options.url) |url| run.addArgs(&.{ "--url", url }) else run.addArgs(&.{ "--url-env", options.url_env });
    run.addArgs(&.{ "--schema", options.schema, "--zom-import", options.zom_import, "--quiet", "--out" });
    const output = run.addOutputFileArg(if (options.out) |out| std.fs.path.basename(out) else "schemas.zig");

    var step = &run.step;
    if (options.out) |out| {
        const update = b.addUpdateSourceFiles();
        update.addCopyFileToSource(output, out);
        step = &update.step;
    }
    if (options.step_name) |name| {
        const top = b.step(name, options.step_description);
        top.dependOn(step);
        step = top;
    }
    return .{ .step = step, .output = output };
}

/// The example programs under `examples/`, each its own package depending
/// on zom by path, the way an application depends on it. They are listed
/// rather than found by scanning, because `examples/` is not in zom's
/// `.paths`: a project that fetches zom doesn't get them, and these steps
/// only run from a checkout.
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

/// The `build_options` module that zom's source imports.
fn buildOptions(b: *std.Build, no_deprecated: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "no_deprecated", no_deprecated);
    return options;
}

const compile_errors_dir = "tests/compile_errors";
const expect_prefix = "// expect: ";

/// One `zig build-obj` per case, with zom as a module import. `zig test` can't
/// say "this must not compile", so each case must exit 1 with the text of every
/// leading `// expect:` line (at least the first line of the file) somewhere in
/// stderr. Several lines let one case check every line of a multi-line error.
/// The cases build zom with `no_deprecated` set, so one of them can check the
/// deprecation error, and no other case relies on a deprecated declaration.
fn addCompileErrorCases(b: *std.Build, step: *std.Build.Step) void {
    const io = b.graph.io;
    const build_options = buildOptions(b, true).getOutput();
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
        run.addArgs(&.{ "--dep", "build_options" });
        run.addPrefixedFileArg("-Mzom=", b.path("src/root.zig"));
        run.addPrefixedFileArg("-Mbuild_options=", build_options);
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
