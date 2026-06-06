const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const client_fflag = b.option(bool, "client", "Whether to build the client module - default: true") orelse true;
    const server_fflag = b.option(bool, "server", "Whether to build the server module - default: false") orelse false;

    const fflags = b.addOptions();
    fflags.addOption(@TypeOf(client_fflag), "client_fflag", client_fflag);
    fflags.addOption(@TypeOf(server_fflag), "server_fflag", server_fflag);

    const mod = b.addModule("dergdrive", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client_dep = b.dependency("dergdrive_client", .{});
    const client_mod = client_dep.module("dergdrive-client");
    // even though the import is added internally in the module itself to guide the language server, without adding it here the build will fail saying there are multiple modules sharing the same root file
    client_mod.addImport("dergdrive", mod);

    const server_dep = b.dependency("dergdrive_server", .{});
    const server_mod = server_dep.module("dergdrive-server");
    server_mod.addImport("dergdrive", mod);

    mod.addOptions("fflags", fflags);
    mod.addImport("dergdrive", mod);
    mod.addImport("dergdrive-client", client_mod);
    mod.addImport("dergdrive-server", server_mod);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dergdrive", .module = mod },
        },
    });

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
    const client_mod_test = b.addTest(.{
        .root_module = client_mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_client_mod_tests = b.addRunArtifact(client_mod_test);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_client_mod_tests.step);
}
