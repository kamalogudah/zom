const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `.pg = true` builds the zom_pg module, which fetches pg.zig.
    const zom_dep = b.dependency("zom", .{ .target = target, .optimize = optimize, .pg = true });

    const exe = b.addExecutable(.{
        .name = "pg_repo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zom", .module = zom_dep.module("zom") },
                .{ .name = "zom_pg", .module = zom_dep.module("zom_pg") },
            },
        }),
    });
    b.installArtifact(exe);

    // The database URL comes from DATABASE_URL, or from the first argument:
    // `zig build run -- postgres://...`.
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Sign two users up in transactions against Postgres (needs DATABASE_URL)");
    run_step.dependOn(&run.step);

    // zom's pg CI workflow runs this against its Postgres service, so the
    // example can't drift from the API, or its output from the README.
    const check = b.addRunArtifact(exe);
    // The database is input the cache can't see.
    check.has_side_effects = true;
    check.expectStdOutEqual(expected_output);
    const test_step = b.step("test", "Run the example against DATABASE_URL and check its output");
    test_step.dependOn(&check.step);
}

const expected_output =
    \\committed: Achieng, with 2 posts
    \\rolled back: DuplicatePrimaryKey (posts_pkey)
    \\  users named Baraka: 0, posts by user 2: 0
    \\active users: 1 of 2
    \\Achieng <achieng@example.com>
    \\  - Relations are values
    \\  - Transactions roll back
    \\
;
