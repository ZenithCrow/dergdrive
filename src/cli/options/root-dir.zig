const std = @import("std");

const cli = @import("dergdrive").cli;

pub const root_dir_opt_name = "root_dir";

pub const option: cli.Option = .{
    .long = "--root-dir",
    .short = 'd',
    .desc = "Specify root directory. All volume file paths are relative to this directory. " ++ cli.command_exec.cliOptOverridesConfigOptDesc(root_dir_opt_name),
    .value = .{
        .eql_sign = false,
        .name = "DIR",
    },
    .cfg_opt = root_dir_opt_name,
};
