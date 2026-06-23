const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;

pub const default_vol_opt_name = "vol_default";

pub const option: cli.Option = .{
    .long = "--volume",
    .short = 'v',
    .desc = "Specify which volume to act upon. " ++ cli.command_exec.cliOptOverridesConfigOptDesc("vol_default"),
    .value = .{
        .eql_sign = false,
        .name = "VOLNAME",
    },
};
