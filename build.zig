const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const client_fflag = b.option(bool, "client", "Whether to build the client module - default: true") orelse true;
    const server_fflag = b.option(bool, "server", "Whether to build the server module - default: false") orelse false;

    const fflags = b.addOptions();
    fflags.addOption(@TypeOf(client_fflag), "client_fflag", client_fflag);
    fflags.addOption(@TypeOf(server_fflag), "server_fflag", server_fflag);

    const version = b.addOptions();
    version.addOption([]const u8, "v", getVersionStr(b));

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
    mod.addOptions("version", version);
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

// taken from build.zig of the zig compiler, I really like their version tagging system :3
fn getVersionStr(b: *std.Build) []const u8 {
    const version: std.SemanticVersion = .{ .major = 0, .minor = 1, .patch = 0 };
    const version_string = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    if (!std.process.can_spawn)
        return version_string;

    var code: u8 = undefined;
    const git_describe_untrimmed = b.runAllowFail(&[_][]const u8{
        "git",
        "-C", b.build_root.path orelse ".", // affects the --git-dir argument
        "--git-dir", ".git", // affected by the -C argument
        "describe", "--match",    "*.*.*", //
        "--tags",   "--abbrev=8",
    }, &code, .ignore) catch return version_string;
    const git_describe = std.mem.trim(u8, git_describe_untrimmed, " \n\r");

    switch (std.mem.countScalar(u8, git_describe, '-')) {
        0 => {
            // Tagged release version (e.g. 0.10.0).
            if (!std.mem.eql(u8, git_describe, version_string)) {
                std.debug.print("version '{s}' does not match Git tag '{s}'\n", .{ version_string, git_describe });
                std.process.exit(1);
            }
            return version_string;
        },
        2 => {
            // Untagged development build (e.g. 0.10.0-dev.2025+ecf0050a9).
            var it = std.mem.splitScalar(u8, git_describe, '-');
            const tagged_ancestor = it.first();
            const commit_height = it.next().?;
            const commit_id = it.next().?;

            const ancestor_ver = std.SemanticVersion.parse(tagged_ancestor) catch unreachable;
            if (version.order(ancestor_ver) != .gt) {
                std.debug.print("version '{f}' must be greater than tagged ancestor '{f}'\n", .{ version, ancestor_ver });
                std.process.exit(1);
            }

            // Check that the commit hash is prefixed with a 'g' (a Git convention).
            if (commit_id.len < 1 or commit_id[0] != 'g') {
                std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
                return version_string;
            }

            // The version is reformatted in accordance with the https://semver.org specification.
            return b.fmt("{s}-dev.{s}+{s}", .{ version_string, commit_height, commit_id[1..] });
        },
        else => {
            std.debug.print("unexpected `git describe` output: {s}\n", .{git_describe});
            return version_string;
        },
    }
}
