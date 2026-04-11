const std = @import("std");

const cli = @import("dergdrive").cli;

pub const option: cli.Option = .{
    .long = "--help",
    .short = 'h',
    .desc = "Show command specific help",
};
