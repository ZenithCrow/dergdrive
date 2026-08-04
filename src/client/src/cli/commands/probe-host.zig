const std = @import("std");
const Environ = std.process.Environ;
const net = std.Io.net;

const client = @import("client");
const options = client.cli.options;
const client_cli = client.cli;
const command_exec = client_cli.command_exec;
const server_opt = options.server;
const ctx_service = client_cli.ctx_service;
const rxtx = client.rxtx;
const PrioReqService = rxtx.PrioReqService;
const connection_service = rxtx.connection_service;
const lenient_resolve_opt = client.cli.options.@"lenient-resolve";
const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const root_cmd_exec = cli.command_exec;
const port_opt = cli.options.port;
const SecAuth = dergdrive.SecAuth;
const SignAlgo = dergdrive.crypt.SignAlgo;

const log = std.log.scoped(.@"client/cli/commands/probe-server");

pub const command: cli.Command = .{
    .name = "probe-host",
    .usage = "probe-host",
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
        lenient_resolve_opt.option,
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
    const ctx: ctx_service.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);

    const conn_details = try connection_service.getConnectionDetails(ctx);

    var conn = try connection_service.connect(conn_details, io);
    defer conn.stream.close(io);

    var writer = conn.stream.writer(io, &.{});
    var reader = conn.stream.reader(io, &.{});

    var req_stor: rxtx.RequestStorage = .init;

    var tailpiece_request_pa: rxtx.pipe_adapter.RequestPipeAdapter = .empty;
    var request_sender: rxtx.RequestSender = try .init(&tailpiece_request_pa, &writer.interface, &req_stor, gpa);
    defer request_sender.deinit(gpa);

    const prio_req_service: PrioReqService = .{ .req_sender = &request_sender };

    var request_receiver: rxtx.RequestReceiver = try .init(&reader.interface, &req_stor, gpa);
    defer request_receiver.deinit(gpa);

    try request_sender.start(io);
    defer request_sender.stop(io);

    try request_receiver.start(io);
    defer request_receiver.stop(io);

    var q_vec = [_]rxtx.RequestStorage.WaitQuery{
        .{
            .result = .{
                .by_resp_type = .{
                    .version = undefined,
                },
            },
        },
        .{
            .result = .{
                .by_resp_type = .{
                    .key_xchg = undefined,
                },
            },
        },
    };
    var wqv: rxtx.RequestStorage.WaitQueryVec = .{ .vec = &q_vec };
    const wqv_idx = try req_stor.addWaitQueryVec(&wqv, io);
    defer req_stor.removeWaitQueryVec(wqv_idx, io);

    try prio_req_service.sendVersion(null, io);

    var sec_auth: SecAuth = .init(null, io);
    const pub_key = sec_auth.getDHXchgPubKey();
    try prio_req_service.sendKeyXchg(pub_key, io);

    var w_buf: [128]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &w_buf);

    var resolved_wqs: usize = 0;
    while (resolved_wqs < q_vec.len) {
        var state_changes: usize = undefined;
        req_stor.waitForIdx(wqv_idx, io, &state_changes) catch {
            {
                try request_sender.error_lock.lock(io);
                defer request_sender.error_lock.unlock(io);

                if (request_sender.err.? == error.WriteFailed) {
                    log.err("Net writer encountered irrecoverable error: {t}", .{writer.err.?});
                    return error.NetWriteFailed;
                }
            }

            {
                try request_receiver.error_lock.lock(io);
                defer request_receiver.error_lock.unlock(io);

                if (request_receiver.err.? == error.ReadFailed) {
                    log.err("Net reader encountered irrecoverable error: {t}", .{reader.err.?});
                    return error.NetReadFailed;
                }
            }

            unreachable;
        };

        log.debug("state changes: {d}", .{state_changes});

        for (0..state_changes) |_| {
            switch (req_stor.consumeCompletedWQ(&wqv, io).?.result.by_resp_type) {
                .version => |v| {
                    if (cli.parser.indexOfOption(args, print_server_version_opt.long, null) != null) {
                        try stdout_w.interface.print("server version: {f}\n", .{v.version});
                        try stdout_w.interface.flush();
                    }
                },
                .key_xchg => |k| {
                    if (cli.parser.indexOfOption(args, print_pubkey_opt.long, null) != null) {
                        try stdout_w.interface.print("server public sign key: {b64}\n", .{k.pub_sign_key});
                        try stdout_w.interface.flush();
                    }

                    log.debug("kxchg_key: {b64}", .{k.pub_xchg_key});
                    log.debug("sign_key: {b64}", .{k.pub_sign_key});
                    log.debug("signature: {b64}", .{k.signature});

                    var verified: bool = undefined;
                    SecAuth.verifyDHXchgPubKeyAuthenticityLog(
                        ctx.conf.*,
                        .{
                            .hostname = conn.host_name_str,
                            .ip_addr = conn.resolved_ip,
                            .hostname_strict = cli.parser.indexOfOption(args, lenient_resolve_opt.option.long, lenient_resolve_opt.option.short) == null,
                        },
                        .fromBytes(k.signature),
                        k.pub_sign_key,
                        k.pub_xchg_key,
                        &verified,
                        gpa,
                        io,
                    ) catch continue;

                    log.info("Server relation is healthy.", .{});
                },
                else => unreachable,
            }
        }

        resolved_wqs += state_changes;
    }
}
