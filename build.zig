const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("dergdrive", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("dergdrive", mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dergdrive", .module = mod },
        },
    });

    const net_mod = b.dependency("znetw", .{
        .target = target,
        .optimize = optimize,
    }).module("znetw");

    exe_mod.addImport("znetw", net_mod);

    const exe = b.addExecutable(.{
        .name = "dergdrive",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const exe_check = b.addExecutable(.{
        .name = "exe_check",
        .root_module = exe_mod,
    });

    const check = b.step("check", "Check if the code compiles");
    check.dependOn(&exe_check.step);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
