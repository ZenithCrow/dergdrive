const std = @import("std");
const dergdrive = @import("dergdrive");

const cli = dergdrive.cli;

const include_rules_opt = @import("../options/include-rules.zig");
const root_dir_opt = @import("../options/root-dir.zig");
const vol_opt = @import("../options/vol.zig");

const log = std.log.scoped(.@"cli/commands/ls-include");

pub const command: cli.Command = .{
    .name = "ls-include",
    .usage = "ls-include [OPTIONS]",
    .desc = "Show a tree of included and/or ignored files in a volume",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, allocator: std.mem.Allocator) cli.Command.ExecError!void {
            return testSync(args, allocator) catch |err| switch (err) {
                cli.Command.ExecError.InvalidSyntax => @errorCast(err),
                cli.Command.ExecError.ReturnStatusFailure => @errorCast(err),
                else => blk: {
                    log.err("Command failed due to error: {t}.", .{err});
                    break :blk cli.Command.ExecError.ReturnStatusFailure;
                },
            };
        }
    }.execFn,
    .options = &.{
        vol_opt.option,
        include_rules_opt.option,
        root_dir_opt.option,
    },
};

fn testSync(args: []const []const u8, allocator: std.mem.Allocator) !void {
    _ = args;
    _ = allocator;
}
