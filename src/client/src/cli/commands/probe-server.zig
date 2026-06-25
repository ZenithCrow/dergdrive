const std = @import("std");
const Environ = std.process.Environ;
const net = std.Io.net;

const client = @import("client");
const options = client.cli.options;
const client_cli = client.cli;
const command_exec = client_cli.command_exec;
const server_opt = options.server;
const service = client_cli.service;
const rxtx = client.rxtx;
const SecAuth = client.SecAuth;
const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const root_cmd_exec = cli.command_exec;
const port_opt = cli.options.port;

const log = std.log.scoped(.@"client/cli/commands/probe-server");

pub const command: cli.Command = .{
    .name = "probe-server",
    .usage = "probe-server",
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

    var conn = try service.connect(ctx, io);
    defer conn.stream.close(io);

    var writer = conn.stream.writer(io, &.{});
    var reader = conn.stream.reader(io, &.{});

    var req_stor: rxtx.RequestStorage = .init;

    var tailpiece_request_pa: rxtx.pipe_adapter.RequestPipeAdapter = .empty;
    var request_sender: rxtx.RequestSender = try .init(&tailpiece_request_pa, &writer.interface, &req_stor, gpa);
    defer request_sender.deinit(gpa);

    var reqest_receiver: rxtx.RequestReceiver = try .init(&reader.interface, &req_stor, gpa);
    defer reqest_receiver.deinit(gpa);

    try request_sender.start(io);
    defer request_sender.stop(io);

    try reqest_receiver.start(io);
    defer reqest_receiver.stop(io);

    try request_sender.prio_request.sendVersion(null, io);

    var sec_auth: SecAuth = .init;
    const pub_key = sec_auth.getDHXchgPubKey(io);
    try request_sender.prio_request.sendKeyXchg(pub_key, io);

    var ver_vec = [_]rxtx.RequestStorage.WaitQuery{
        .{
            .result = .{
                .by_resp_type = .{
                    .version = undefined,
                },
            },
        },
    };
    var serversion_wqv: rxtx.RequestStorage.WaitQueryVec = .{ .vec = &ver_vec };

    var state_changes: usize = undefined;
    req_stor.waitFor(&serversion_wqv, io, &state_changes) catch {
        //  TODO: investigate
        log.err("Subsystem failure.", .{});
        return error.SubsystemFailure;
    };

    var w_buf: [128]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &w_buf);

    if (cli.parser.indexOfOption(args, print_server_version_opt.long, null) != null) {
        try stdout_w.interface.print("server version: {f}\n", .{ver_vec[0].result.by_resp_type.version.version});
    }

    var kxchg_vec = [_]rxtx.RequestStorage.WaitQuery{
        .{
            .result = .{
                .by_resp_type = .{
                    .key_xchg = undefined,
                },
            },
        },
    };
    var kxchg_wqv: rxtx.RequestStorage.WaitQueryVec = .{ .vec = &kxchg_vec };

    req_stor.waitFor(&kxchg_wqv, io, &state_changes) catch {
        //  TODO: investigate
        log.err("Subsystem failure.", .{});
        return error.SubsystemFailure;
    };

    const key_xchg = kxchg_vec[0].result.by_resp_type.key_xchg;
    if (cli.parser.indexOfOption(args, print_pubkey_opt.long, null) != null) {
        try stdout_w.interface.print("server public sign key: {b64}\n", .{key_xchg.pub_sign_key});
    }

    try stdout_w.interface.flush();

    var verified: bool = undefined;
    if (SecAuth.verifyDHXchgPubKeyAuthenticity(
        ctx.conf.*,
        conn.address,
        .fromBytes(key_xchg.signature),
        key_xchg.pub_sign_key,
        key_xchg.pub_xchg_key,
        &verified,
        gpa,
        io,
    )) |_| {
        log.info("Server relation is healthy.", .{});
    } else |err| switch (err) {
        SecAuth.VerifyError.FirstTimeHost => log.warn("Authenticity of this host can't be verified, since it is not included in known hosts. Tread carefully.", .{}),
        SecAuth.VerifyError.OpenKnownHostsFailed => log.err("Couldn't open known hosts file. The signature was successfully verified. Tread carefully.", .{}),
        SecAuth.VerifyError.IdentityElement => log.err("Failed to verified host signature. This is a huge security risk. Tread extra carefully.", .{}),
        else => log.err("Couldn't verify host signature due to error: {t}. Tread extra carefully.", .{err}),
    }
}
