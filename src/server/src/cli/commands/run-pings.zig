const std = @import("std");
const net = std.Io.net;

const cli = @import("dergdrive").cli;
const port_opt = cli.options.port;
const server = @import("server");
const server_cli = server.cli;
const command_exec = server_cli.command_exec;
const ConnectionWorker = server.rxtx.ConnectionWorker;
const NetAcceptor = server.rxtx.NetAcceptor;

const log = std.log.scoped(.@"server/cli/commands/run-pings");

pub const command: cli.Command = .{
    .name = "run-pings",
    .usage = "run-pings [OPTIONS]",
    .desc = "Run in light mode, only respond to fixed selection of requests",
    .long_desc = "The server will neither process nor execute any storage requests and will respord only to 'ping' type requests.",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *std.process.Environ.Map, gpa: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            return runPing(args, emap, gpa, io) catch |err| switch (err) {
                cli.Command.ExecError.InvalidSyntax => @errorCast(err),
                cli.Command.ExecError.TooFewArguments => @errorCast(err),
                else => cli.Command.ExecError.ReturnStatusFailure,
            };
        }
    }.execFn,
    .options = &.{port_opt.option},
};

fn runPing(args: []const []const u8, emap: *std.process.Environ.Map, gpa: std.mem.Allocator, io: std.Io) !void {
    const ctx: command_exec.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);

    const server_port = cli.command_exec.getCliThenConfigValue(ctx.env, port_opt.port_opt_name, ctx.args, port_opt.option) orelse {
        log.err(port_opt.option.notSetErrorMsg("Server port"), .{});
        return error.ServerPortNotSet;
    };

    const port_num = std.fmt.parseInt(u16, server_port, 10) catch |err| {
        log.err("Couldn't parse port number: {t}. Server port must be a 16-bit unsigned integer.", .{err});
        return err;
    };

    var net_acc: NetAcceptor = .init(port_num);
    defer net_acc.deinit(gpa, io);

    try net_acc.start(gpa, io);
    defer net_acc.stop(io);

    log.info("server running", .{});

    var r_buf: [64]u8 = undefined;
    var stdin_r = std.Io.File.stdin().readerStreaming(io, &r_buf);
    var dw: std.Io.Writer.Discarding = .init(&.{});
    _ = try stdin_r.interface.streamDelimiter(&dw.writer, '\n');

    log.info("server shut down", .{});
}
