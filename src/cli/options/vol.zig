const std = @import("std");

const cli = @import("dergdrive").cli;

pub const default_vol_opt_name = "vol_default";

pub const option: cli.Option = .{
    .long = "--volume",
    .short = 'v',
    .desc = "Specify which volume to act upon. When this option is not used, value of 'vol_default' config option will be used if it is set.",
    .value = .{
        .eql_sign = false,
        .name = "VOLNAME",
    },
};
