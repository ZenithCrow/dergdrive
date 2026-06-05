const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("dergdrive-server", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_mod = b.createModule(.{
        .root_source_file = b.path("../root.zig"),
        .target = target,
        .optimize = optimize,
    });

    mod.addImport("server", mod);
    mod.addImport("dergdrive", root_mod);
}
