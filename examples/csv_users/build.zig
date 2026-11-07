const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // One dependency, several modules: zom ships its adapters as modules
    // of the same package. zom_pg isn't built (no `.pg = true`), so this
    // build never fetches pg.zig.
    const zom_dep = b.dependency("zom", .{ .target = target, .optimize = optimize });
    const zom = zom_dep.module("zom");
    const zom_csv = zom_dep.module("zom_csv");

    const exe = b.addExecutable(.{
        .name = "csv_users",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zom", .module = zom },
                .{ .name = "zom_csv", .module = zom_csv },
            },
        }),
    });
    b.installArtifact(exe);

    // `data/` is found relative to the working directory, so run from here
    // whichever directory `zig build` was started in.
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Print each CSV user with their in-memory posts");
    run_step.dependOn(&run.step);

    // The root build's `test` step runs this, so the example can't drift
    // from the API, or its output from what examples/README.md shows.
    const check = b.addRunArtifact(exe);
    check.setCwd(b.path("."));
    check.expectStdOutEqual(expected_output);
    const test_step = b.step("test", "Run the example and check its output");
    test_step.dependOn(&check.step);
}

const expected_output =
    \\Achieng <achieng@example.com>
    \\  - Relations are values
    \\  - Gateways side by side
    \\Baraka <baraka@example.com>
    \\  (no posts)
    \\Wanjiru <wanjiru@example.com>
    \\  - Reading CSV with zom
    \\
;
