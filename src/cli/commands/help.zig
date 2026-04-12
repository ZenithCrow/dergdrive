const std = @import("std");

const cli = @import("dergdrive").cli;

pub const command: cli.Command = .{
    .name = "help",
    .usage = "help",
    .desc = "Print this help and exit",
    .exec_fn = struct {
        pub fn execFn(_: []const []const u8, _: std.mem.Allocator) cli.Command.ExecError!void {
            cli.command_exec.printHelp();
        }
    }.execFn,
    .options = &.{},
};
