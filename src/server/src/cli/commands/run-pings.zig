const std = @import("std");
const net = std.Io.net;

const cli = @import("dergdrive").cli;
const server = @import("server");
const server_cli = server.cli;
const command_exec = server_cli.command_exec;
const ConnectionWorker = server.rxtx.ConnectionWorker;

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
    .options = &.{},
};

fn runPing(args: []const []const u8, emap: *std.process.Environ.Map, gpa: std.mem.Allocator, io: std.Io) !void {
    const ctx: command_exec.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);

    const ip: net.IpAddress = .{ .ip4 = .loopback(6767) };
    var tcp_server = try ip.listen(io, .{});

    log.info("waiting for connection...", .{});
    const stream = try tcp_server.accept(io);

    var cw: ConnectionWorker = try .init(stream, gpa, io);
    defer cw.deinit(gpa);

    try cw.start(io);
    defer cw.stop(io);

    log.info("server running", .{});

    var r_buf: [64]u8 = undefined;
    var stdin_r = std.Io.File.stdin().readerStreaming(io, &r_buf);
    var dw: std.Io.Writer.Discarding = .init(&.{});
    _ = try stdin_r.interface.streamDelimiter(&dw.writer, '\n');

    log.info("server shut down", .{});
}
