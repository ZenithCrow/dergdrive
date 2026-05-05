const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");

const Command = @import("Command.zig");
const help_cmd = @import("commands/help.zig");
const @"ls-include_cmd" = @import("commands/ls-include.zig");
const @"test-sync_cmd" = @import("commands/test-sync.zig");
const @"test-pipe_cmd" = @import("commands/test-pipe.zig");
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

const commands: []const Command = &(.{
    help_cmd.command,
    @"ls-include_cmd".command,
} ++ if (builtin.mode == .Debug) .{
    @"test-sync_cmd".command,
    @"test-pipe_cmd".command,
} else .{});
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

pub fn exec(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) ExecError!void {
    if (args.len == 0) {
        printHelp(io);
        return ExecError.NoArgsProvided;
    }

    if (command_map.get(args[0])) |command| {
        if (parser.indexOfOption(args, help_opt.option.long, help_opt.option.short) != null) {
            printCmdHelp(command, io);
        } else try command.exec_fn(args[1..], emap, allocator, io);
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

pub const ParamContext = struct {
    args: []const []const u8,
    conf: *dergdrive.conf.Conf,
    env: *dergdrive.conf.Env,
    vol: ?[]const u8 = null,
    root_path: ?[]const u8 = null,
    include_rules_path: ?[]const u8 = null,

    pub fn deinit(self: ParamContext, allocator: std.mem.Allocator) void {
        allocator.destroy(self.conf);

        self.env.deinit();
        allocator.destroy(self.env);
    }
};

const load_evs_err_notice = "Failed to load envs due to error: {t}.";

pub fn initBroadContext(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) dergdrive.cli.Command.ExecError!ParamContext {
    const conf = allocator.create(dergdrive.conf.Conf) catch |err| {
        log.err(load_evs_err_notice, .{err});
        return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
    };
    errdefer allocator.destroy(conf);

    conf.* = .init("", emap);

    const env = allocator.create(dergdrive.conf.Env) catch |err| {
        log.err(load_evs_err_notice, .{err});
        return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
    };
    errdefer allocator.destroy(env);

    env.* = .init(conf.*, allocator, io);
    errdefer env.deinit();

    env.loadEnvs() catch |err| {
        log.err(load_evs_err_notice, .{err});
        return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
    };

    const vol = if (getCliThenConfigValue(env, vol_opt.default_vol_opt_name, args, vol_opt.option)) |v| blk: {
        conf.* = .init(v, emap);

        // replace env with newer one having volume context
        env.deinit();
        env.* = .init(conf.*, allocator, io);
        env.loadEnvs() catch |err| {
            log.err(load_evs_err_notice, .{err});
            return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
        };

        break :blk v;
    } else null;

    return .{
        .args = args,
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

pub const ParamContextValues = struct {
    root_dir_iterable: std.Io.Dir,
    rule_text: []const u8,

    pub fn init(ctx: ParamContext, allocator: std.mem.Allocator, io: std.Io) !ParamContextValues {
        const root_path = if (ctx.root_path) |v| v else {
            log.err(Option.opt_not_set_template, .{ "Root directory", @"root-dir_opt".root_dir_opt_name, @"root-dir_opt".option.long });
            return error.RootDirNotSet;
        };

        var root_dir_wd_res = try ctx.env.getWithCwd(@"include-rules_opt".include_rules_opt_name, false, io);
        const root_dir_not_cli = parser.getAssociatedValue(ctx.args, @"include-rules_opt".option.long, @"include-rules_opt".option.short, @"include-rules_opt".option.value.?.eql_sign) == null;
        const root_dir_wd = if (root_dir_not_cli and root_dir_wd_res != null)
            root_dir_wd_res.?.cwd
        else
            std.Io.Dir.cwd();

        defer if (root_dir_wd_res) |*res| res.cwd.close(io);

        const root_dir = root_dir_wd.openDir(io, root_path, .{ .iterate = true }) catch |err| {
            log.err("Couldn't open root directory {s} due to error: {t}.", .{ root_path, err });
            return error.RootDirOpenFailed;
        };

        const include_rules_path = if (ctx.include_rules_path) |v| v else {
            log.err(Option.opt_not_set_template, .{ "Include rules file", @"include-rules_opt".include_rules_opt_name, @"include-rules_opt".option.long });
            return error.IncludeRulesFileNotSet;
        };

        var include_rules_wd_res = try ctx.env.getWithCwd(@"include-rules_opt".include_rules_opt_name, false, io);
        const include_rules_not_cli = parser.getAssociatedValue(ctx.args, @"include-rules_opt".option.long, @"include-rules_opt".option.short, @"include-rules_opt".option.value.?.eql_sign) == null;
        const include_rules_wd = if (include_rules_not_cli and include_rules_wd_res != null)
            include_rules_wd_res.?.cwd
        else
            std.Io.Dir.cwd();

        defer if (include_rules_wd_res) |*res| res.cwd.close(io);

        const rule_text = blk: {
            const rule_file = include_rules_wd.openFile(io, include_rules_path, .{}) catch |err| {
                log.err("Couldn't open include rules file {s} due to error: {t}.", .{ include_rules_path, err });
                return error.RuleFileOpenFailed;
            };
            defer rule_file.close(io);

            const size = try rule_file.length(io);

            var fr = rule_file.reader(io, &.{});
            break :blk try fr.interface.readAlloc(allocator, size);
        };

        return .{
            .root_dir_iterable = root_dir,
            .rule_text = rule_text,
        };
    }

    pub fn deinit(self: *ParamContextValues, allocator: std.mem.Allocator, io: std.Io) void {
        self.root_dir_iterable.close(io);
        allocator.free(self.rule_text);
    }
};
