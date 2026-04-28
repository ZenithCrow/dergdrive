const std = @import("std");

const dergdrive = @import("dergdrive");

const Command = @import("Command.zig");
const help_cmd = @import("commands/help.zig");
const @"ls-include_cmd" = @import("commands/ls-include.zig");
const Option = @import("Option.zig");
const help_opt = @import("options/help.zig");
const @"include-rules_opt" = @import("options/include-rules.zig");
const @"root-dir_opt" = @import("options/root-dir.zig");
const vol_opt = @import("options/vol.zig");
const parser = @import("parser.zig");

pub const prog_name = "dergdrive";

pub const ExecError = error{
    NoArgsProvided,
    UnknownCommand,
} || Command.ExecError;

const commands: []const Command = &.{
    help_cmd.command,
    @"ls-include_cmd".command,
};
const CommandTup = struct { []const u8, Command };
const command_tups: [commands.len]CommandTup = blk: {
    var tups: [commands.len]CommandTup = undefined;
    for (commands, &tups) |command, *tup| {
        tup.@"0" = command.name;
        tup.@"1" = command;
    }
    break :blk tups;
};

const global_options: []const Option = &.{help_opt.option};

const command_map: std.StaticStringMap(Command) = .initComptime(command_tups);

const log = std.log.scoped(.@"cli/command_exec");

pub fn exec(args: []const []const u8, allocator: std.mem.Allocator) ExecError!void {
    if (args.len == 0) {
        printHelp();
        return ExecError.NoArgsProvided;
    }

    if (command_map.get(args[0])) |command| {
        if (parser.indexOfOption(args, help_opt.option.long, help_opt.option.short) != null) {
            printCmdHelp(command);
        } else try command.exec_fn(args[1..], allocator);
    } else {
        printHelp();
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

pub fn printHelp() void {
    std.log.info(param_notice, .{});
    std.log.info("Usage: {s} COMMAND [OPTIONS]", .{prog_name});

    var w_buf: [512]u8 = undefined;
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

pub fn printCmdHelp(cmd: Command) void {
    std.log.info(param_notice, .{});
    std.log.info("Usage: {s} {s}", .{ prog_name, cmd.usage });

    var w_buf: [512]u8 = undefined;
    var stderr_w = std.fs.File.stderr().writerStreaming(&w_buf);
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

pub const ParamContext = struct {
    conf: *dergdrive.conf.Conf,
    env: *dergdrive.conf.Env,
    vol: ?[]const u8 = null,
    root_path: ?[]const u8 = null,
    include_rules_path: ?[]const u8 = null,

    pub fn deinitBroadContext(self: ParamContext, allocator: std.mem.Allocator) void {
        allocator.destroy(self.conf);

        self.env.deinit();
        allocator.destroy(self.env);
    }
};

const load_evs_err_notice = "Failed to load envs due to error: {t}.";

pub fn initBroadContext(args: []const []const u8, allocator: std.mem.Allocator) dergdrive.cli.Command.ExecError!ParamContext {
    const conf = allocator.create(dergdrive.conf.Conf) catch |err| {
        log.err(load_evs_err_notice, .{err});
        return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
    };
    errdefer allocator.destroy(conf);

    conf.* = .init("");

    const env = allocator.create(dergdrive.conf.Env) catch |err| {
        log.err(load_evs_err_notice, .{err});
        return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
    };
    errdefer allocator.destroy(env);

    env.* = .init(conf.*, allocator);
    errdefer env.deinit();

    env.loadEnvs() catch |err| {
        log.err(load_evs_err_notice, .{err});
        return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
    };

    const vol = if (getCliThenConfigValue(env, vol_opt.default_vol_opt_name, args, vol_opt.option)) |v| blk: {
        conf.* = .init(v);

        // replace env with newer one having volume context
        env.deinit();
        env.* = .init(dergdrive.conf.Conf.g_conf, allocator);
        env.loadEnvs() catch |err| {
            log.err(load_evs_err_notice, .{err});
            return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
        };

        break :blk v;
    } else null;

    return .{
        .conf = conf,
        .env = env,
        .vol = vol,
        .root_path = getCliThenConfigValue(env, @"root-dir_opt".root_dir_opt_name, args, @"root-dir_opt".option),
        .include_rules_path = getCliThenConfigValue(env, @"include-rules_opt".include_rules_opt_name, args, @"include-rules_opt".option),
    };
}

pub fn getCliThenConfigValue(env: *const dergdrive.conf.Env, config_opt_name: []const u8, args: []const []const u8, cli_opt: Option) ?[]const u8 {
    return if (parser.getAssociatedValue(args, cli_opt.long, cli_opt.short, (cli_opt.value orelse return null).eql_sign)) |v| v else if (env.get(config_opt_name)) |v| v else null;
}
