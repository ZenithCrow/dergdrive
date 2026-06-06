const std = @import("std");

const dergdrive = @import("dergdrive");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    std.Io.File.stderr().enableAnsiEscapeCodes(io) catch {};
    std.Io.File.stdout().enableAnsiEscapeCodes(io) catch {};

    dergdrive.cli.command_exec.exec(args[1..], init.environ_map, allocator, io) catch |err| switch (err) {
        error.ReturnStatusFailure => std.process.exit(1),
        else => |e| {
            var w = std.Io.File.stderr().writerStreaming(io, &.{});
            w.interface.writeByte('\n') catch return w.err.?;

            switch (e) {
                error.UnknownCommand => std.log.err("unrecognized command: {s}", .{args[1]}),
                error.TooFewArguments => std.log.err("expected command argument", .{}),
                error.InvalidSyntax => std.log.err("invalid syntax", .{}),
            }

            std.process.exit(64);
        },
    };
}
