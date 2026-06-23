const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;

pub const include_rules_opt_name = "include_rules";

pub const option: cli.Option = .{
    .long = "--include-rules",
    .short = 'i',
    .desc = "Specify a file containing the include rules. " ++ cli.command_exec.cliOptOverridesConfigOptDesc("include_rules"),
    .value = .{
        .eql_sign = false,
        .name = "FILE",
    },
};
