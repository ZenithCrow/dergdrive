const std = @import("std");

const dergdrive = @import("dergdrive");
const Command = dergdrive.cli.Command;
const command_exec_root = dergdrive.cli.command_exec;

pub const command_list: []const Command = &.{};

pub fn printServerHelp(io: std.Io) void {
    std.log.info(command_exec_root.param_notice, .{});
    std.log.info("Usage: {s} server COMMAND", .{command_exec_root.prog_name});

    var stderr_w = std.Io.File.stderr().writerStreaming(io, &command_exec_root.stderr_w_buf);
    stderr_w.interface.writeAll(
        \\
        \\Server commands:
        \\
        \\
    ) catch return;

    for (command_list) |command| {
        command_exec_root.printEvenlySpaced(&stderr_w.interface, command.name, command.desc) catch return;
    }

    stderr_w.interface.print(
        \\
        \\Global command options:
        \\
        \\
    ,
        .{},
    ) catch return;

    for (command_exec_root.global_options) |option| {
        command_exec_root.printOptionEvenlySpaced(&stderr_w.interface, option) catch return;
    }

    stderr_w.interface.flush() catch {};
}
