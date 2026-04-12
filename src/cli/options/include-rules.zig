const std = @import("std");

const cli = @import("dergdrive").cli;

pub const include_rules_opt_name = "include_rules";

pub const option: cli.Option = .{
    .long = "--include-rules",
    .short = 'i',
    .desc = "Specify a file containing the include rules. When this option is not used, value of 'include_rules' config option will be used if it is set.",
    .value = .{
        .eql_sign = false,
        .name = "FILE",
    },
};
