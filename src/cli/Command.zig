const std = @import("std");

const cli = @import("dergdrive").cli;

pub const ExecError = error{ InvalidSyntax, ReturnStatusFailure };

name: []const u8,
usage: []const u8,
desc: []const u8,
long_desc: ?[]const u8 = null,
exec_fn: *const fn (args: []const []const u8, allocator: std.mem.Allocator) ExecError!void,
options: []const cli.Option,
