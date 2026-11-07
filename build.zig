const std = @import("std");

/// zom is one package that exports several modules: the core, `zom`, and one
/// module per adapter (`zom_csv`, `zom_yaml`, `zom_sql`, `zom_pg`,
/// `zom_sqlite`, `zom_tigerbeetle`). An
/// application depends on the package once and picks the modules it uses:
///
///     const dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
///     const zom = dep.module("zom");
///     const zom_csv = dep.module("zom_csv");
///
/// zom-pg needs pg.zig, a lazy dependency, so it only exists when asked for
/// with `.pg = true`: an application that doesn't use Postgres never fetches
/// pg.zig. zom-tigerbeetle likewise needs TigerBeetle's prebuilt C client,
/// so it only exists with `.tigerbeetle = true`, and zom-sqlite compiles
/// the SQLite amalgamation, so it only exists with `.sqlite = true`. The adapters' code lives under `adapters/<name>/src` and imports
/// zom only through its public module, so an adapter can still move to a
/// repo of its own later without code changes (see plan.md, section 3.2).
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // On by default in a checkout of zom itself (the root package, whose
    // pkg_hash is empty), so `zig build test` covers zom-pg; off by default
    // when zom is someone else's dependency.
    const with_pg = b.option(bool, "pg", "Build the zom_pg module (fetches pg.zig)") orelse (b.pkg_hash.len == 0);
    const with_sqlite = b.option(bool, "sqlite", "Build the zom_sqlite module (fetches the SQLite amalgamation)") orelse (b.pkg_hash.len == 0);
    const with_tigerbeetle = b.option(bool, "tigerbeetle", "Build the zom_tigerbeetle module (fetches TigerBeetle's C client)") orelse (b.pkg_hash.len == 0);

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

    // The code blocks of README.md and docs/, compiled against the public module like a user would.
    const readme = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/readme.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zom", .module = mod }},
    }) });
    test_step.dependOn(&b.addRunArtifact(readme).step);

    const compile_errors = b.step("compile-errors", "Check that tests/compile_errors/*.zig fail with the expected message");
    addCompileErrorCases(b, compile_errors, compile_errors_dir, &.{});
    test_step.dependOn(compile_errors);

    // The adapters with no dependency beyond zom (and each other).
    _ = addAdapter(b, test_adapters, "csv", &.{.{ .name = "zom", .module = mod }}, target, optimize);
    _ = addAdapter(b, test_adapters, "yaml", &.{.{ .name = "zom", .module = mod }}, target, optimize);
    const zom_sql = addAdapter(b, test_adapters, "sql", &.{.{ .name = "zom", .module = mod }}, target, optimize);

    // Every lazy dependency this configuration needs is asked for before
    // returning `error.LazyDependencyNeeded`, so they are all fetched in one go.
    var missing = false;

    if (with_pg) {
        if (lazyDependency(b, "pg", .{ .target = target, .optimize = optimize }, &missing)) |pg_dep| {
            addPg(b, test_adapters, mod, zom_sql.module, pg_dep.module("pg"), target, optimize);
        }
    } else {
        const fail = b.addFail("zom-pg is off: pass -Dpg=true (or `.pg = true` to b.dependency)");
        b.step("test-pg", "Run zom-pg's tests (its database tests need ZOM_PG_URL)").dependOn(&fail.step);
    }

    const test_sqlite = b.step("test-sqlite", "Run zom-sqlite's tests (in-memory databases, no server needed)");
    if (with_sqlite) {
        const sqlite_dep = lazyDependency(b, "sqlite", .{}, &missing);
        const translate_c = lazyTranslator(b, &missing);
        if (sqlite_dep != null and translate_c != null) {
            addSqlite(b, test_adapters, test_sqlite, mod, zom_sql.module, sqlite_dep.?, translate_c.?, target, optimize);
        }
    } else {
        const fail = b.addFail("zom-sqlite is off: pass -Dsqlite=true (or `.sqlite = true` to b.dependency)");
        test_sqlite.dependOn(&fail.step);
    }

    const test_tigerbeetle = b.step("test-tigerbeetle", "Run zom-tigerbeetle's tests (its cluster test needs ZOM_TB_ADDRESSES)");
    if (with_tigerbeetle) {
        const tb_dep = lazyDependency(b, "tigerbeetle_go", .{}, &missing);
        const translate_c = lazyTranslator(b, &missing);
        if (tb_dep != null and translate_c != null) {
            addTigerBeetle(b, test_adapters, test_tigerbeetle, mod, tb_dep.?, translate_c.?, target, optimize);
        }
    } else {
        const fail = b.addFail("zom-tigerbeetle is off: pass -Dtigerbeetle=true (or `.tigerbeetle = true` to b.dependency)");
        test_tigerbeetle.dependOn(&fail.step);
    }
    test_step.dependOn(test_adapters);

    const test_examples = b.step("test-examples", "Build and run each examples/<name> package, checking its output");
    addExampleTests(b, test_examples, optimize);
    test_step.dependOn(test_examples);

    if (missing) return error.LazyDependencyNeeded;
}

/// `b.dependencyLazy`, except that a dependency not fetched yet sets
/// `missing` and returns null, so the caller can go on asking for the others.
fn lazyDependency(b: *std.Build, name: []const u8, args: anytype, missing: *bool) ?*std.Build.Dependency {
    return b.dependencyLazy(name, args) catch |err| switch (err) {
        error.LazyDependencyNeeded => {
            missing.* = true;
            return null;
        },
    };
}

/// The translate-c package, which turns a C header into a Zig module (Zig
/// 0.17 removed `@cImport` and deprecated `b.addTranslateC`). It is lazy:
/// only zom-sqlite and zom-tigerbeetle need it.
fn lazyTranslator(b: *std.Build, missing: *bool) ?*std.Build.Dependency {
    return lazyDependency(b, "translate_c", .{}, missing);
}

/// A C header translated to Zig: the module to import, and the generated
/// file (the compile-error cases pass it to `zig build-obj` themselves).
const Translated = struct {
    module: *std.Build.Module,
    output_file: std.Build.LazyPath,
};

const TranslateOptions = struct {
    name: []const u8,
    header: std.Build.LazyPath,
    link_libc: bool,
    /// Gives every struct field a zero default, as Zig 0.16's built-in
    /// translate-c did, so `.{ .id = x }` leaves the rest zeroed.
    default_init: bool = false,
};

/// Translates a C header with translate-c's `Translator`. `translate_c`
/// comes from `lazyTranslator`, so the package is fetched and its build.zig
/// can be imported.
fn translateHeader(
    b: *std.Build,
    translate_c: *std.Build.Dependency,
    options: TranslateOptions,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) Translated {
    const Translator = if (b.lazyImport(@This(), "translate_c")) |tc| tc.Translator else @panic("translate_c is not fetched");
    const t: Translator = .init(translate_c, .{
        .name = options.name,
        .c_source_file = options.header,
        .target = target,
        .optimize = optimize,
        .link_libc = options.link_libc,
        .default_init = options.default_init,
    });
    return .{ .module = t.mod, .output_file = t.output_file };
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
    optimize: std.lang.Optimize,
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
    optimize: std.lang.Optimize,
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
    run_infer.addPassthruArgs();
    b.step("infer", "Run zom-pg-infer (pass its options after --)").dependOn(&run_infer.step);
}

/// The `zom_sqlite` module and its tests. The amalgamation is compiled into
/// the module, and its header translated, so nothing is needed from the
/// system but libc.
fn addSqlite(
    b: *std.Build,
    test_adapters: *std.Build.Step,
    test_sqlite: *std.Build.Step,
    zom: *std.Build.Module,
    zom_sql: *std.Build.Module,
    sqlite_dep: *std.Build.Dependency,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const header = translateHeader(b, translate_c, .{
        .name = "sqlite3",
        .header = sqlite_dep.path("sqlite3.h"),
        .link_libc = true,
    }, target, optimize);
    const adapter = addAdapter(b, test_adapters, "sqlite", &.{
        .{ .name = "zom", .module = zom },
        .{ .name = "zom_sql", .module = zom_sql },
        .{ .name = "sqlite3", .module = header.module },
    }, target, optimize);
    adapter.module.link_libc = true;
    adapter.module.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &sqlite_flags,
    });
    test_sqlite.dependOn(&adapter.run_tests.step);
}

/// How zom-sqlite compiles SQLite. `SQLITE_CASE_SENSITIVE_LIKE` makes `LIKE`
/// match case as the memory adapter does (`ilike` is rendered as
/// `LOWER(x) LIKE LOWER(y)`), `SQLITE_DQS=0` makes `"x"` an identifier only,
/// as zom-sql quotes them, and UBSan is off for SQLite's C, which relies on
/// behaviour it flags (it is SQLite's to test, not zom's).
const sqlite_flags = [_][]const u8{
    "-std=c99",
    "-fno-sanitize=undefined",
    "-DSQLITE_CASE_SENSITIVE_LIKE",
    "-DSQLITE_DQS=0",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_DEFAULT_FOREIGN_KEYS=1",
    "-DSQLITE_OMIT_LOAD_EXTENSION",
    "-DSQLITE_OMIT_DEPRECATED",
    "-DSQLITE_OMIT_SHARED_CACHE",
    "-DSQLITE_USE_ALLOCA",
};

/// The `zom_tigerbeetle` module and its tests. TigerBeetle's C client comes
/// prebuilt from the tigerbeetle-go release tarball (`native/`): its header,
/// translated here, and one static library per supported target. Releases
/// of TigerBeetle pin an older Zig, so its source can't be built by this
/// one; the C ABI doesn't care which Zig built the library.
fn addTigerBeetle(
    b: *std.Build,
    test_adapters: *std.Build.Step,
    test_tigerbeetle: *std.Build.Step,
    zom: *std.Build.Module,
    tb_dep: *std.Build.Dependency,
    translate_c: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const t = target.result;
    const library: ?[]const u8 = switch (t.os.tag) {
        .linux, .macos => switch (t.cpu.arch) {
            .x86_64, .aarch64 => b.fmt("native/libtb_client_{t}-{t}.a", .{ t.cpu.arch, t.os.tag }),
            else => null,
        },
        .windows => if (t.cpu.arch == .x86_64) "native/tb_client_x86_64-windows.lib" else null,
        else => null,
    };
    const lib_path = library orelse {
        const fail = b.addFail(b.fmt("zom-tigerbeetle: TigerBeetle's C client has no library for {t}-{t}; " ++
            "it ships x86_64 and aarch64 for linux and macos, and x86_64 for windows", .{ t.cpu.arch, t.os.tag }));
        test_tigerbeetle.dependOn(&fail.step);
        test_adapters.dependOn(&fail.step);
        return;
    };

    // zom-tigerbeetle builds the client's records as `.{ .id = x, ... }`
    // and relies on the other fields being zero.
    const tb_client = translateHeader(b, translate_c, .{
        .name = "tb_client",
        .header = tb_dep.path("native/tb_client.h"),
        .link_libc = false,
        .default_init = true,
    }, target, optimize);
    const adapter = addAdapter(b, test_adapters, "tigerbeetle", &.{
        .{ .name = "zom", .module = zom },
        .{ .name = "tb_client", .module = tb_client.module },
    }, target, optimize);
    // The library starts a thread and does its own I/O through libc.
    adapter.module.link_libc = true;
    adapter.module.addObjectFile(tb_dep.path(lib_path));
    if (t.os.tag == .windows) {
        adapter.module.linkSystemLibrary("ws2_32", .{});
        adapter.module.linkSystemLibrary("ntdll", .{});
    }
    // The cluster tests read ZOM_TB_ADDRESSES, which the cache can't see;
    // without it they are skipped.
    adapter.run_tests.has_side_effects = true;
    test_tigerbeetle.dependOn(&adapter.run_tests.step);

    // Cases that must not compile against zom_tigerbeetle (e.g. an update
    // of immutable transfers). They only type-check, so nothing is linked.
    addCompileErrorCases(b, test_tigerbeetle, "adapters/tigerbeetle/tests/compile_errors", &.{
        .{ .name = "zom_tigerbeetle", .root = b.path("adapters/tigerbeetle/src/root.zig"), .deps = &.{ "zom", "tb_client" } },
        .{ .name = "tb_client", .root = tb_client.output_file, .deps = &.{} },
    });
    test_adapters.dependOn(test_tigerbeetle);
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
    const output = run.addOutputFileArg2(if (options.out) |out| std.fs.path.basename(out) else "schemas.zig", .{});

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
/// only run from a checkout. examples/pg_repo and examples/double_entry
/// are not listed: they need a Postgres server and a TigerBeetle cluster,
/// so zom-pg's CI workflow (pg.yml) and zom-tigerbeetle's (tigerbeetle.yml)
/// run them instead.
const example_dirs = [_][]const u8{"csv_users"};

/// Runs `zig build test` inside each example's directory: it builds the
/// program, runs it, and compares its stdout with the expected output.
fn addExampleTests(b: *std.Build, step: *std.Build.Step, optimize: std.lang.Optimize) void {
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

/// A module a compile-error case can import besides zom: `name`, rooted at
/// `root`, which imports `deps` (zom, build_options or another extra).
const CaseModule = struct {
    name: []const u8,
    root: std.Build.LazyPath,
    deps: []const []const u8,
};

/// One `zig build-obj` per case in `cases_dir`, with zom (and `extra`) as module imports. `zig test` can't
/// say "this must not compile", so each case must exit 1 with the text of every
/// leading `// expect:` line (at least the first line of the file) somewhere in
/// stderr. Several lines let one case check every line of a multi-line error.
/// The cases build zom with `no_deprecated` set, so one of them can check the
/// deprecation error, and no other case relies on a deprecated declaration.
fn addCompileErrorCases(b: *std.Build, step: *std.Build.Step, cases_dir: []const u8, extra: []const CaseModule) void {
    const io = b.graph.io;
    const build_options = buildOptions(b, true).getOutput();
    // The cases are listed and read at configure time, so tell the
    // configuration cache: a new, removed or edited case reconfigures.
    b.dependOnDirectoryContents(b.path(cases_dir));
    var dir = b.root.openDir(io, cases_dir, .{ .iterate = true }) catch |err|
        std.debug.panic("unable to open {s}: {t}", .{ cases_dir, err });
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch |err| std.debug.panic("unable to list {s}: {t}", .{ cases_dir, err })) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;

        const case_path = b.path(b.fmt("{s}/{s}", .{ cases_dir, entry.name }));
        b.dependOnFileContents(case_path);
        const source = dir.readFileAlloc(io, entry.name, b.allocator, .limited(64 * 1024)) catch |err|
            std.debug.panic("unable to read {s}/{s}: {t}", .{ cases_dir, entry.name, err });
        if (!std.mem.startsWith(u8, source, expect_prefix))
            std.debug.panic("{s}/{s}: first line must be `{s}<error text>`", .{ cases_dir, entry.name, expect_prefix });

        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build-obj", "-fno-emit-bin", "--dep", "zom" });
        run.setName(b.fmt("compile-error {s}", .{entry.name}));
        for (extra) |m| run.addArgs(&.{ "--dep", m.name });
        run.addFileArg2(case_path, .{ .prefix = "-Mroot=" });
        run.addArgs(&.{ "--dep", "build_options" });
        run.addFileArg2(b.path("src/root.zig"), .{ .prefix = "-Mzom=" });
        for (extra) |m| {
            for (m.deps) |dep| run.addArgs(&.{ "--dep", dep });
            run.addFileArg2(m.root, .{ .prefix = b.fmt("-M{s}=", .{m.name}) });
        }
        run.addFileArg2(build_options, .{ .prefix = "-Mbuild_options=" });
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
