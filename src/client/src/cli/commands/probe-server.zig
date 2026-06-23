const std = @import("std");
const Environ = std.process.Environ;

const client = @import("client");
const options = client.cli.options;
const client_cli = client.cli;
const command_exec = client_cli.command_exec;
const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;

const log = std.log.scoped(.@"client/cli/commands/probe-server");

pub const command: cli.Command = .{
    .name = "probe-server",
    .usage = "probe-server [OPTIONS]",
    .desc = "Connect to a given server, try to establish a secure channel and print the results",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *Environ.Map, gpa: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            return probeServer(args, emap, gpa, io) catch |err| switch (err) {
                cli.Command.ExecError.InvalidSyntax => @errorCast(err),
                cli.Command.ExecError.ReturnStatusFailure => @errorCast(err),
                else => blk: {
                    log.err("Command failed due to error: {t}.", .{err});
                    break :blk cli.Command.ExecError.ReturnStatusFailure;
                },
            };
        }
    }.execFn,
    .options = &.{
        options.vol.option,
        server_opt,
        port_opt,
        print_pubkey_opt,
        print_server_version_opt,
    },
};

const server_opt: cli.Option = .{
    .long = "--server",
    .short = 's',
    .desc = "The server to connect to. Can be a domain name or an IPv4/IPv6 address. " ++ cli.command_exec.cliOptOverridesConfigOptDesc("server_addr") ++ " To specify port, use the '--port' option.",
    .value = .{
        .eql_sign = false,
        .name = "ADDRESS",
    },
};

const port_opt: cli.Option = .{
    .long = "--port",
    .short = 'p',
    .desc = "The server port. " ++ cli.command_exec.cliOptOverridesConfigOptDesc("server_port"),
    .value = .{
        .eql_sign = false,
        .name = "PORT",
    },
};

const print_pubkey_opt: cli.Option = .{
    .long = "--print-pubkey",
    .desc = "Print the servers public key",
};

const print_server_version_opt: cli.Option = .{
    .long = "--serversion",
    .desc = "Print the server version and compatibility info",
};

fn probeServer(args: []const []const u8, emap: *Environ.Map, gpa: std.mem.Allocator, io: std.Io) !void {
    const ctx: command_exec.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);
}
