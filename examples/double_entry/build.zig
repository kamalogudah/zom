const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // `.tigerbeetle = true` builds the zom_tigerbeetle module, which fetches
    // TigerBeetle's prebuilt C client.
    const zom_dep = b.dependency("zom", .{ .target = target, .optimize = optimize, .tigerbeetle = true });
    // The client is a lazy dependency of zom's: on the first build it isn't
    // fetched yet, so zom has no zom_tigerbeetle module. Returning lets the
    // build runner fetch it and run this function again.
    const zom_tigerbeetle = zom_dep.builder.modules.get("zom_tigerbeetle") orelse return;

    const exe = b.addExecutable(.{
        .name = "double_entry",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zom", .module = zom_dep.module("zom") },
                .{ .name = "zom_tigerbeetle", .module = zom_tigerbeetle },
            },
        }),
    });
    b.installArtifact(exe);

    // The cluster comes from TB_ADDRESSES, or from the first argument:
    // `zig build run -- 3000`.
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Open two accounts, post transfers and read the balances (needs TB_ADDRESSES)");
    run_step.dependOn(&run.step);

    // zom's TigerBeetle CI workflow runs this against its dev cluster, so
    // the example can't drift from the API.
    const check = b.addRunArtifact(exe);
    // The cluster is input the cache can't see.
    check.has_side_effects = true;
    check.expectStdOutEqual(expected_output);
    const test_step = b.step("test", "Run the example against TB_ADDRESSES and check its output");
    test_step.dependOn(&check.step);
}

const expected_output =
    \\opened: bank, customer (ledger 700)
    \\deposit: 1000
    \\linked: purchase 250 + fee 5, both posted
    \\refused: withdrawal 740 + fee 10: event 1 failed with ExceedsCredits, nothing posted
    \\balances:
    \\  bank      debits 1000  credits  255  net  -745
    \\  customer  debits  255  credits 1000  net  +745
    \\customer history:
    \\  +1000  balance 1000
    \\  -250   balance 750
    \\  -5     balance 745
    \\
;
