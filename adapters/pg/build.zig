const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zom = b.dependency("zom", .{ .target = target, .optimize = optimize }).module("zom");
    const zom_sql = b.dependency("zom_sql", .{ .target = target, .optimize = optimize }).module("zom_sql");
    const pg = b.dependency("pg", .{ .target = target, .optimize = optimize }).module("pg");

    const mod = b.addModule("zom_pg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zom", .module = zom },
            .{ .name = "zom_sql", .module = zom_sql },
            .{ .name = "pg", .module = pg },
        },
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    // The integration tests read ZOM_PG_URL; without it they are skipped.
    run_tests.has_side_effects = true;

    const test_step = b.step("test", "Run zom-pg tests (the lint suite needs ZOM_PG_URL)");
    test_step.dependOn(&run_tests.step);

    // zom-pg-infer, installed so that `addInferStep` can find it with
    // `Dependency.artifact`.
    const infer_exe = b.addExecutable(.{
        .name = "zom-pg-infer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/infer_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zom_sql", .module = zom_sql },
                .{ .name = "zom_pg", .module = mod },
            },
        }),
    });
    b.installArtifact(infer_exe);
    test_step.dependOn(&infer_exe.step);

    const run_infer = b.addRunArtifact(infer_exe);
    if (b.args) |args| run_infer.addArgs(args);
    const infer_step = b.step("infer", "Run zom-pg-infer (pass its options after --)");
    infer_step.dependOn(&run_infer.step);
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
///     const zom_pg_build = @import("zom_pg");
///     _ = zom_pg_build.addInferStep(b, .{ .out = "src/schemas.zig" });
///
/// Then `DATABASE_URL=postgres://... zig build infer`.
pub fn addInferStep(b: *std.Build, options: InferOptions) Infer {
    const dep = b.dependencyFromBuildZig(@This(), .{ .target = b.graph.host });
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
