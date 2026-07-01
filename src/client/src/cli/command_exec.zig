const std = @import("std");
const builtin = @import("builtin");

const client = @import("client");
const commands = client.cli.commands;
const @"ls-include_cmd" = commands.@"ls-include";
const @"test-pipe_cmd" = commands.@"test-pipe";
const @"test-sync_cmd" = commands.@"test-sync";
const @"probe-host_cmd" = commands.@"probe-host";
const client_cli = client.cli;
const options = client_cli.options;
const vol_opt = options.vol;
const @"include-rules_opt" = options.@"include-rules";
const Conf = client.Conf;
const server_opt = options.server;
const dergdrive = @import("dergdrive");
const Command = dergdrive.cli.Command;
const command_exec_root = dergdrive.cli.command_exec;
const options_root = dergdrive.cli.options;
const Option = dergdrive.cli.Option;
const parser = dergdrive.cli.parser;
const Env = dergdrive.conf.Env;
const @"root-dir_opt" = dergdrive.cli.options.@"root-dir";
const port_opt = options_root.port;

pub const command_list: []const Command = &(.{
    @"ls-include_cmd".command,
    @"probe-host_cmd".command,
} ++ if (builtin.mode == .Debug) .{
    @"test-sync_cmd".command,
    @"test-pipe_cmd".command,
} else .{});
