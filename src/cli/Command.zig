const std = @import("std");

pub const ExecError = error{ InvalidSyntax, ReturnStatusFailure };

name: []const u8,
desc: []const u8,
exec_fn: *const fn (args: []const []const u8, allocator: std.mem.Allocator) ExecError!void,
