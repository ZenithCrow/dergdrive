const std = @import("std");
const builtin = @import("builtin");

const client = @import("client");
const commands = client.cli.commands;
const @"ls-include_cmd" = commands.@"ls-include";
const @"test-pipe_cmd" = commands.@"test-pipe";
const @"test-sync_cmd" = commands.@"test-sync";
const @"probe-server_cmd" = commands.@"probe-server";
const client_cli = client.cli;
const options = client_cli.options;
const vol_opt = options.vol;
const @"include-rules_opt" = options.@"include-rules";
const Conf = client.Conf;
const dergdrive = @import("dergdrive");
const Command = dergdrive.cli.Command;
const command_exec_root = dergdrive.cli.command_exec;
const Option = dergdrive.cli.Option;
const parser = dergdrive.cli.parser;
const Env = dergdrive.conf.Env;
const @"root-dir_opt" = dergdrive.cli.options.@"root-dir";

const log = std.log.scoped(.@"client/cli/command_exec");

pub const command_list: []const Command = &(.{
    @"ls-include_cmd".command,
    @"probe-server_cmd".command,
} ++ if (builtin.mode == .Debug) .{
    @"test-sync_cmd".command,
    @"test-pipe_cmd".command,
});

pub const ParamContext = struct {
    args: []const []const u8,
    conf: *Conf,
    env: *Env,
    vol: ?[]const u8 = null,
    root_path: ?[]const u8 = null,
    include_rules_path: ?[]const u8 = null,

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

        conf.* = .init("", emap);

        const env = allocator.create(Env) catch |err| {
            log.err(Env.load_evs_err_notice, .{err});
            return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
        };
        errdefer allocator.destroy(env);

        env.* = .init(conf.root_conf, allocator, io);
        errdefer env.deinit();

        env.loadEnvs() catch |err| {
            log.err(Env.load_evs_err_notice, .{err});
            return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
        };

        const vol = if (command_exec_root.getCliThenConfigValue(env, vol_opt.default_vol_opt_name, args, vol_opt.option)) |v| blk: {
            conf.* = .init(v, emap);

            // replace env with newer one having volume context
            env.deinit();
            env.* = .init(conf.root_conf, allocator, io);
            env.loadEnvs() catch |err| {
                log.err(Env.load_evs_err_notice, .{err});
                return dergdrive.cli.Command.ExecError.ReturnStatusFailure;
            };

            break :blk v;
        } else null;

        return .{
            .args = args,
            .conf = conf,
            .env = env,
            .vol = vol,
            .root_path = command_exec_root.getCliThenConfigValue(env, @"root-dir_opt".root_dir_opt_name, args, @"root-dir_opt".option),
            .include_rules_path = command_exec_root.getCliThenConfigValue(env, @"include-rules_opt".include_rules_opt_name, args, @"include-rules_opt".option),
        };
    }
};

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
