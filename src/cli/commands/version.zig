const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const ExecError = cli.Command.ExecError;

pub const command: cli.Command = .{
    .name = "version",
    .usage = "version",
    .desc = "Print the build version along with present modules",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, _: *std.process.Environ.Map, _: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            var w_buf: [64]u8 = undefined;
            var stdout_w = std.Io.File.stdout().writerStreaming(io, &w_buf);

            if (cli.parser.indexOfOption(args, ver_only_opt.long, ver_only_opt.short) != null) {
                stdout_w.interface.writeAll(dergdrive.version ++ "\n") catch return ExecError.ReturnStatusFailure;
            } else {
                stdout_w.interface.writeAll("Dergdrive " ++ dergdrive.version ++ " " ++ switch (@as(u2, @intFromBool(dergdrive.is_client)) << 1 | @as(u2, @intFromBool(dergdrive.is_server))) {
                    0b00 => "whar?",
                    0b01 => "server only",
                    0b10 => "client only",
                    0b11 => "client and server",
                } ++ "\n") catch return ExecError.ReturnStatusFailure;
            }

            stdout_w.interface.flush() catch return ExecError.ReturnStatusFailure;
        }
    }.execFn,
    .options = &.{},
};

const ver_only_opt: cli.Option = .{
    .long = "--version-only",
    .short = 'v',
    .desc = "Only print the version string",
};
