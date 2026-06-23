const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const client = dergdrive.client;
const server = dergdrive.server;
const is_client = dergdrive.is_client;
const is_server = dergdrive.is_server;

const Command = @import("Command.zig");
const help_cmd = @import("commands/help.zig");
const version_cmd = @import("commands/version.zig");
const Option = @import("Option.zig");
const help_opt = @import("options/help.zig");
const parser = @import("parser.zig");

const is_bimodule = is_client and is_server;

pub const prog_name = "dergdrive";

pub const ExecError = error{
    UnknownCommand,
} || Command.ExecError;

const global_commands: []const Command = &[_]Command{
    help_cmd.command,
    version_cmd.command,
} ++ if (is_server) &[_]Command{server.cli.commands.server.command} else &[_]Command{};

pub const global_options: []const Option = &.{help_opt.option};

const CommandFflags = struct {
    cmd: Command,
    server: bool,
};

pub const CommandTup = struct { []const u8, CommandFflags };

const server_prefix = "server ";
fn makeTuplesOf(comptime command_list: []const Command, is_server_cmds: bool) [command_list.len]CommandTup {
    var tups: [command_list.len]CommandTup = undefined;
    for (command_list, &tups) |command, *tup| {
        tup.@"0" = (if (is_bimodule and is_server_cmds) server_prefix else "") ++ command.name;
        tup.@"1" = .{
            .cmd = command,
            .server = is_server_cmds,
        };
    }

    return tups;
}

const command_tups: []const CommandTup = &(makeTuplesOf(global_commands, false) ++ switch (@as(u2, @intFromBool(is_client)) << 1 | @as(u2, @intFromBool(is_server))) {
    0b00 => .{},
    0b01 => makeTuplesOf(server.cli.command_exec.command_list, false),
    0b10 => makeTuplesOf(client.cli.command_exec.command_list, false),
    0b11 => makeTuplesOf(client.cli.command_exec.command_list, false) ++ makeTuplesOf(server.cli.command_exec.command_list, true),
});

const command_map: std.StaticStringMap(CommandFflags) = .initComptime(command_tups);

const log = std.log.scoped(.@"cli/command_exec");

var command_name_buf: [128]u8 = blk: {
    var buf: [128]u8 = undefined;
    std.mem.copyForwards(u8, buf[0..server_prefix.len], server_prefix);
    break :blk buf;
};

pub fn exec(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) ExecError!void {
    if (args.len == 0) {
        printHelp(io);
        return ExecError.TooFewArguments;
    }

    var cmd_key: []const u8 = args[0];
    if (comptime (is_bimodule)) {
        if (std.mem.eql(u8, cmd_key, "server")) {
            if (args.len <= 1) {
                server.cli.command_exec.printServerHelp(io);
                return ExecError.TooFewArguments;
            }

            // check if command supplied to `server` is not a flag (e.g. -h for help)
            if (args[1][0] != '-') {
                cmd_key = args[1];
                std.mem.copyForwards(u8, command_name_buf[server_prefix.len .. server_prefix.len + cmd_key.len], cmd_key);
                cmd_key = command_name_buf[0 .. server_prefix.len + cmd_key.len];
            }
        }
    }

    if (command_map.get(cmd_key)) |command| {
        if (parser.indexOfOption(args, help_opt.option.long, help_opt.option.short) != null) {
            printCmdHelp(command.cmd, io);
        } else try command.cmd.exec_fn(args[1..], emap, allocator, io);
    } else {
        printHelp(io);
        return ExecError.UnknownCommand;
    }
}

pub fn printEvenlySpaced(w: *std.Io.Writer, point: []const u8, desc: []const u8) std.Io.Writer.Error!void {
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

pub fn printOptionEvenlySpaced(w: *std.Io.Writer, option: Option) std.Io.Writer.Error!void {
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

pub const param_notice = "Parameters in capitals are user provided. If enclosed in brackets [], the parameter is optional and/or has a default value.";

pub var stderr_w_buf: [512]u8 = undefined;

pub fn printHelp(io: std.Io) void {
    std.log.info(param_notice, .{});
    std.log.info("Usage: {s} COMMAND [OPTIONS]", .{prog_name});

    var stderr_w = std.Io.File.stderr().writerStreaming(io, &stderr_w_buf);
    stderr_w.interface.writeAll(
        \\
        \\Commands:
        \\
        \\
    ) catch return;

    for (command_tups) |cmd_ff| {
        printEvenlySpaced(&stderr_w.interface, cmd_ff.@"0", cmd_ff.@"1".cmd.desc) catch return;
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
    std.log.info("Usage: {s} {s} [OPTIONS]", .{ prog_name, cmd.usage });

    var stderr_w = std.Io.File.stderr().writerStreaming(io, &stderr_w_buf);
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

pub fn getCliThenConfigValue(env: *const dergdrive.conf.Env, config_opt_name: []const u8, args: []const []const u8, cli_opt: Option) ?[]const u8 {
    return if (parser.getAssociatedValue(args, cli_opt.long, cli_opt.short, (cli_opt.value orelse return null).eql_sign)) |v| v else if (env.get(config_opt_name)) |v| v else null;
}

pub fn cliOptOverridesConfigOptDesc(comptime config_opt_name: []const u8) []const u8 {
    return "When this option is not used, value of '" ++ config_opt_name ++ "' config option will be used if it is set.";
}
