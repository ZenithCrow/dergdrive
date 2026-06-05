const std = @import("std");

const cli = @import("dergdrive").cli;

pub const root_dir_opt_name = "root_dir";

pub const option: cli.Option = .{
    .long = "--root-dir",
    .short = 'd',
    .desc = "Specify root directory. All volume file paths are relative to this directory. When this option is not used, value of 'root_dir' config option will be used if it is set.",
    .value = .{
        .eql_sign = false,
        .name = "DIR",
    },
};
