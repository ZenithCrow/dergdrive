const std = @import("std");

const dergdrive = @import("dergdrive");
const znetw = @import("znetw");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    dergdrive.cli.command_exec.exec(args[1..], allocator) catch |err| switch (err) {
        error.UnknownCommand => {
            std.log.err("unknown command: {s}", .{args[1]});
            std.process.exit(64);
        },
        error.NoArgsProvided => {},
        error.InvalidSyntax => {
            std.log.err("invalid syntax", .{});
            std.process.exit(64);
        },
        error.ReturnStatusFailure => std.process.exit(1),
    };
}
