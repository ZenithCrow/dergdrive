const std = @import("std");

const cli = @import("dergdrive").cli;

pub const command: cli.Command = .{
    .name = "server",
    .usage = "server COMMAND",
    .desc = "Execute a server command",
    .long_desc = "Used in dergdrive builds with both client and server modules to distiguish between client and server commands. If only the server module is present, conveniently, commands can still be run this way.",
    .exec_fn = struct {
        pub fn execFn(_: []const []const u8, _: *std.process.Environ.Map, _: std.mem.Allocator, _: std.Io) cli.Command.ExecError!void {
            return cli.Command.ExecError.TooFewArguments;
        }
    }.execFn,
    .options = &.{},
};
