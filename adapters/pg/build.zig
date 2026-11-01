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
}
