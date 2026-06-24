const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;

pub const port_opt_name = "server_port";

pub const option: cli.Option = .{
    .long = "--port",
    .short = 'p',
    .desc = "The server port. " ++ cli.command_exec.cliOptOverridesConfigOptDesc(port_opt_name),
    .value = .{
        .eql_sign = false,
        .name = "PORT",
    },
    .cfg_opt = port_opt_name,
};
