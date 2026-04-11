const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;

pub const command: cli.Command = .{
    .name = "ls-include",
    .desc = "Show a tree of included and/or excluded files in a volume given by a 'include.txt' file",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, allocator: std.mem.Allocator) cli.Command.ExecError!void {}
    }.execFn,
};
