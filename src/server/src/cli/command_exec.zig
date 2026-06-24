const std = @import("std");

const dergdrive = @import("dergdrive");
const Command = dergdrive.cli.Command;
const command_exec_root = dergdrive.cli.command_exec;
const Conf = dergdrive.conf.Conf;
const Env = dergdrive.conf.Env;
const @"root-dir_opt" = dergdrive.cli.options.@"root-dir";
const Option = dergdrive.cli.Option;
const parser = dergdrive.cli.parser;

const log = std.log.scoped(.@"server/cli/command_exec");

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

pub const ParamContext = struct {
    args: []const []const u8,
    conf: *Conf,
    env: *Env,
    root_path: ?[]const u8 = null,

    pub fn deinit(self: ParamContext, allocator: std.mem.Allocator) void {
        allocator.destroy(self.conf);

        self.env.deinit();
        allocator.destroy(self.env);
    }

    pub fn init(args: []const []const u8, emap: *const std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) dergdrive.cli.Command.ExecError!ParamContext {
        const conf = allocator.create(Conf) catch |err| {
            log.err(Env.load_evs_err_notice, .{err});
            return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
        };
        errdefer allocator.destroy(conf);

        conf.* = .{ .emap = emap };

        const env = allocator.create(Env) catch |err| {
            log.err(Env.load_evs_err_notice, .{err});
            return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
        };
        errdefer allocator.destroy(env);

        env.* = .init(conf.*, allocator, io);
        errdefer env.deinit();

        env.loadEnvs() catch |err| {
            log.err(Env.load_evs_err_notice, .{err});
            return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
        };

        return .{
            .args = args,
            .conf = conf,
            .env = env,
            .root_path = command_exec_root.getCliThenConfigValue(env, @"root-dir_opt".root_dir_opt_name, args, @"root-dir_opt".option),
        };
    }
};

pub const ParamContextValues = struct {
    root_dir_iterable: std.Io.Dir,

    pub fn init(ctx: ParamContext, io: std.Io) !ParamContextValues {
        const root_path = if (ctx.root_path) |v| v else {
            log.err(@"root-dir_opt".option.notSetErrorMsg("Root directory"), .{});
            return error.RootDirNotSet;
        };

        var root_dir_wd_res = try ctx.env.getWithCwd(@"root-dir_opt".root_dir_opt_name, false, io);
        const root_dir_not_cli = parser.getAssociatedValue(ctx.args, @"root-dir_opt".option.long, @"root-dir_opt".option.short, @"root-dir_opt".option.value.?.eql_sign) == null;
        const root_dir_wd = if (root_dir_not_cli and root_dir_wd_res != null)
            root_dir_wd_res.?.cwd
        else
            std.Io.Dir.cwd();

        defer if (root_dir_wd_res) |*res| res.cwd.close(io);

        const root_dir = root_dir_wd.openDir(io, root_path, .{ .iterate = true }) catch |err| {
            log.err("Couldn't open root directory {s} due to error: {t}.", .{ root_path, err });
            return error.RootDirOpenFailed;
        };

        return .{
            .root_dir_iterable = root_dir,
        };
    }

    pub fn deinit(self: *ParamContextValues, io: std.Io) void {
        self.root_dir_iterable.close(io);
    }
};
