const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const client = dergdrive.client;
const is_client = dergdrive.is_client;
const is_server = dergdrive.is_server;

const Command = @import("Command.zig");
const help_cmd = @import("commands/help.zig");
const Option = @import("Option.zig");
const help_opt = @import("options/help.zig");
const parser = @import("parser.zig");

pub const prog_name = "dergdrive";

pub const ExecError = error{
    NoArgsProvided,
    UnknownCommand,
} || Command.ExecError;

const global_commands: []const Command = &.{
    help_cmd.command,
};

const global_options: []const Option = &.{help_opt.option};

const CommandFflags = struct {
    cmd: Command,
    server: bool,
};

pub const CommandTup = struct { []const u8, CommandFflags };

fn makeTupleOf(comptime command_list: []const Command, is_server_cmd: bool) [command_list.len]CommandTup {
    var tups: [command_list.len]CommandTup = undefined;
    for (command_list, &tups) |command, *tup| {
        tup.@"0" = command.name;
        tup.@"1" = .{
            .cmd = command,
            .server = is_server_cmd,
        };
    }

    return tups;
}

const command_tups: []const CommandTup = &(makeTupleOf(global_commands, false) ++ switch (@as(u2, @intFromBool(is_client)) << 1 | @as(u2, @intFromBool(is_server))) {
    0b00 => .{},
    0b01 => .{},
    0b10 => makeTupleOf(client.cli.command_exec.command_list, false),
    else => .{},
});

const command_map: std.StaticStringMap(CommandFflags) = .initComptime(command_tups);

const log = std.log.scoped(.@"cli/command_exec");

pub fn exec(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) ExecError!void {
    if (args.len == 0) {
        printHelp(io);
        return ExecError.NoArgsProvided;
    }

    if (command_map.get(args[0])) |command| {
        if (parser.indexOfOption(args, help_opt.option.long, help_opt.option.short) != null) {
            printCmdHelp(command.cmd, io);
        } else try command.cmd.exec_fn(args[1..], emap, allocator, io);
    } else {
        printHelp(io);
        return ExecError.UnknownCommand;
    }
}

fn printEvenlySpaced(w: *std.Io.Writer, point: []const u8, desc: []const u8) std.Io.Writer.Error!void {
    const desc_tab = 24;
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

fn printOptionEvenlySpaced(w: *std.Io.Writer, option: Option) std.Io.Writer.Error!void {
    var f_buf: [128]u8 = undefined;
    var fw = std.Io.Writer.fixed(&f_buf);

    if (option.short) |flag| {
        fw.print("-{c} ", .{flag}) catch unreachable;
    } else fw.writeAll("   ") catch unreachable;

    try fw.writeAll(option.long);

    if (option.value) |val| {
        try fw.writeByte(if (val.eql_sign) '=' else ' ');

        if (val.default != null)
            try fw.writeByte('[');

        try fw.writeAll(val.name orelse "VALUE");

        if (val.default) |def| {
            try fw.print("] (default: {s})", .{def});
        }
    }

    try printEvenlySpaced(w, fw.buffered(), option.desc);
}

const param_notice = "Parameters in capitals are user provided. If enclosed in brackets [], the parameter is optional and/or has a default value.";

pub fn printHelp(io: std.Io) void {
    std.log.info(param_notice, .{});
    std.log.info("Usage: {s} COMMAND [OPTIONS]", .{prog_name});

    var w_buf: [512]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writerStreaming(io, &w_buf);
    stderr_w.interface.writeAll(
        \\
        \\Commands:
        \\
        \\
    ) catch return;

    for (global_commands) |command| {
        printEvenlySpaced(&stderr_w.interface, command.name, command.desc) catch return;
    }

    stderr_w.interface.print(
        \\
        \\Global command options:
        \\
        \\
    ,
        .{},
    ) catch return;

    for (global_options) |option| {
        printOptionEvenlySpaced(&stderr_w.interface, option) catch return;
    }

    stderr_w.interface.flush() catch {};
}

pub fn printCmdHelp(cmd: Command, io: std.Io) void {
    std.log.info(param_notice, .{});
    std.log.info("Usage: {s} {s}", .{ prog_name, cmd.usage });

    var w_buf: [512]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writerStreaming(io, &w_buf);
    stderr_w.interface.print(
        \\
        \\Brief:
        \\
        \\  {s}
        \\
    ,
        .{cmd.desc},
    ) catch return;

    if (cmd.long_desc) |ld| {
        stderr_w.interface.print(
            \\
            \\Description:
            \\
            \\  {s}
            \\
        ,
            .{ld},
        ) catch return;
    }

    if (cmd.options.len > 0) {
        stderr_w.interface.writeAll(
            \\
            \\Options:
            \\
            \\
        ) catch return;

        for (cmd.options) |opt| {
            printOptionEvenlySpaced(&stderr_w.interface, opt) catch return;
        }
    }

    stderr_w.interface.print(
        \\
        \\Global command options:
        \\
        \\
    ,
        .{},
    ) catch return;

    for (global_options) |option| {
        printOptionEvenlySpaced(&stderr_w.interface, option) catch return;
    }

    stderr_w.interface.flush() catch {};
}
