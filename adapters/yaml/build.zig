const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zom's build.zig calls `b.addModule("zom", ...)`, which is what makes
    // `.module("zom")` available here.
    const zom = b.dependency("zom", .{ .target = target, .optimize = optimize }).module("zom");

    const mod = b.addModule("zom_yaml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zom", .module = zom }},
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run zom-yaml tests");
    test_step.dependOn(&run_tests.step);
}
