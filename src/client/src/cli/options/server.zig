const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;

pub const server_opt_name = "server_addr";

pub const option: cli.Option = .{
    .long = "--server",
    .short = 's',
    .desc = "The server to connect to. Can be a domain name or an IPv4/IPv6 address. " ++ cli.command_exec.cliOptOverridesConfigOptDesc(server_opt_name) ++ " To specify port, use the '--port' option.",
    .value = .{
        .eql_sign = false,
        .name = "ADDRESS",
    },
    .cfg_opt = server_opt_name,
};
