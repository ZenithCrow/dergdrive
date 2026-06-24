const std = @import("std");
const Environ = std.process.Environ;
const net = std.Io.net;

const client = @import("client");
const options = client.cli.options;
const client_cli = client.cli;
const command_exec = client_cli.command_exec;
const server_opt = options.server;
const service = client_cli.service;
const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const root_cmd_exec = cli.command_exec;
const port_opt = cli.options.port;

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
        server_opt.option,
        port_opt.option,
        print_pubkey_opt,
        print_server_version_opt,
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
    const ctx: service.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);

    var stream = try service.connect(ctx, io);

    _ = &stream;
}
