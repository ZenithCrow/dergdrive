const std = @import("std");

const Command = @import("Command.zig");
const help = @import("commands/help.zig");
const help_option = @import("commands/help_option.zig");
const Option = @import("Option.zig");

const prog_name = "dergdrive";

pub const ExecError = error{
    NoArgsProvided,
    UnknownCommand,
} || Command.ExecError;

const commands: []const Command = &.{help.command};
const CommandTup = struct { []const u8, Command };
const command_tups: [commands.len]CommandTup = blk: {
    var tups: [commands.len]CommandTup = undefined;
    for (commands, &tups) |command, *tup| {
        tup.@"0" = command.name;
        tup.@"1" = command;
    }
    break :blk tups;
};

const global_options: []const Option = &.{help_option.option};

const command_map: std.StaticStringMap(Command) = .initComptime(command_tups);

pub fn exec(args: []const []const u8, allocator: std.mem.Allocator) ExecError!void {
    if (args.len == 0) {
        printHelp();
        return ExecError.NoArgsProvided;
    }

    if (command_map.get(args[0])) |command| {
        try command.exec_fn(args[1..], allocator);
    } else {
        printHelp();
        return ExecError.UnknownCommand;
    }
}

var w_buf: [512]u8 = undefined;
pub fn printHelp() void {
    std.log.info("Usage: {s} [command] [options]", .{prog_name});

    var stderr_w = std.fs.File.stderr().writerStreaming(&w_buf);
    stderr_w.interface.writeAll(
        \\
        \\Commands:
        \\
        \\
    ) catch return;

    for (commands) |command| {
        printEvenlySpaced(&stderr_w.interface, command.name, command.desc) catch return;
    }

    stderr_w.interface.print(
        \\
        \\Global options:
        \\
        \\
    ,
        .{},
    ) catch return;

    for (global_options) |option| {
        var f_buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&f_buf);

        if (option.short) |flag| {
            w.print("-{c}, ", .{flag}) catch unreachable;
        }

        w.writeAll(option.long) catch {};

        printEvenlySpaced(&stderr_w.interface, w.buffered(), option.desc) catch return;
    }

    stderr_w.interface.flush() catch {};
}

fn printEvenlySpaced(w: *std.Io.Writer, point: []const u8, desc: []const u8) std.Io.Writer.Error!void {
    const desc_tab = 20;
    const space_around = 2;

    var name_buf: [desc_tab]u8 = undefined;

    for (&name_buf) |*c| {
        c.* = ' ';
    }

    try w.writeAll(name_buf[0..space_around]);

    if (point.len > desc_tab - 2 * space_around) {
        try w.print("{s}\n{s}", .{ point, &name_buf });
    } else {
        std.mem.copyForwards(u8, name_buf[space_around .. space_around + point.len], point);
        try w.writeAll(name_buf[space_around..]);
    }

    try w.writeAll(desc);
    try w.writeByte('\n');
}
