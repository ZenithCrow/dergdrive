const std = @import("std");
pub const GetServerPublicSignKeyError = std.Io.Cancelable;
const net = std.Io.net;
const Stream = net.Stream;

const client = @import("client");
const ParamContext = client.cli.ctx_service.ParamContext;
const cli = client.cli;
const options = cli.options;
const server_opt = options.server;
const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;
const SignAlgo = crypt.SignAlgo;
const command_exec_root = dergdrive.cli.command_exec;
const glob_options = dergdrive.cli.options;
const port_opt = glob_options.port;

const RequestReceiver = @import("RequestReceiver.zig");
const RequestStorage = @import("RequestStorage.zig");

pub const QueryServerPublicSignKeyError = error{
    ConnectionResetByServer,
    StreamReadFailed,
    ServerPublicSignKeyNonCanonical,
} || std.Io.Cancelable || std.Io.ConcurrentError || std.mem.Allocator.Error || RequestStorage.AddWaitQueryVecError || RequestStorage.WaitForError;

const log = std.log.scoped(.@"client/rxtx/connection_service");

pub const unresolvable_host_msg = "Host name '{s}' won't be resolved due the following issue: {t}.";
pub const port_num_parse_msg = "Couldn't parse port number due to error: {t}. Server port must be a 16-bit unsigned integer.";

pub const ConnectionDetails = struct {
    host_name_str: []const u8,
    port: u16,
};

pub const Connection = struct {
    ip_addr_str_buf: [64]u8 = undefined,
    addr_str: []const u8,
    stream: Stream,
};

pub fn getConnectionDetails(ctx: ParamContext) !ConnectionDetails {
    const server_addr = command_exec_root.getCliThenConfigValue(ctx.env, server_opt.server_opt_name, ctx.args, server_opt.option) orelse {
        log.err(server_opt.option.notSetErrorMsg("Server address"), .{});
        return error.ServerAddressNotSet;
    };

    const server_port = command_exec_root.getCliThenConfigValue(ctx.env, port_opt.port_opt_name, ctx.args, port_opt.option) orelse {
        log.err(port_opt.option.notSetErrorMsg("Server port"), .{});
        return error.ServerPortNotSet;
    };

    const port_num = std.fmt.parseInt(u16, server_port, 10) catch |err| {
        log.err(port_num_parse_msg, .{err});
        return err;
    };

    return .{
        .host_name_str = server_addr,
        .port = port_num,
    };
}

pub fn connect(conn_details: ConnectionDetails, io: std.Io) !Connection {
    const connect_options: std.Io.net.IpAddress.ConnectOptions = .{ .mode = .stream, .protocol = .tcp, .timeout = .none };
    const connect_err_msg = "Couldn't connect to host due to error: {t}.";

    var connection: Connection = .{
        .addr_str = undefined,
        .stream = undefined,
    };

    const ip_addr = std.Io.net.IpAddress.parse(conn_details.host_name_str, conn_details.port) catch {
        connection.addr_str = conn_details.host_name_str;
        const host_name = std.Io.net.HostName.init(conn_details.host_name_str) catch |err| {
            log.err(unresolvable_host_msg, .{ conn_details.host_name_str, err });
            return error.UnresolvableHostName;
        };

        connection.stream = host_name.connect(io, conn_details.port, connect_options) catch |err| {
            log.err(connect_err_msg, .{err});
            return error.UnableToConnect;
        };

        return connection;
    };

    var addr_writer = std.Io.Writer.fixed(&connection.ip_addr_str_buf);
    addr_writer.print("{f}", .{ip_addr}) catch unreachable;

    log.debug("{f}", .{ip_addr});

    connection.stream = ip_addr.connect(io, connect_options) catch |err| {
        log.err(connect_err_msg, .{err});
        return error.UnableToConnect;
    };

    return connection;
}

pub fn queryServerPublicSignKey(conn: Connection, gpa: std.mem.Allocator, io: std.Io) QueryServerPublicSignKeyError!SignAlgo.PublicKey {
    var req_stor: RequestStorage = .init;
    defer req_stor.deinit(gpa);

    var net_r = conn.stream.reader(io, &.{});
    var req_rec: RequestReceiver = try .init(&net_r.interface, &req_stor, gpa);
    defer req_rec.deinit(gpa);

    try req_rec.start(io);
    defer req_rec.stop(io);

    var q_vec = [_]RequestStorage.WaitQuery{.{
        .result = .{
            .by_resp_type = .{
                .key_xchg = undefined,
            },
        },
    }};
    var wqv: RequestStorage.WaitQueryVec = .{ .vec = &q_vec };

    var state_changes: usize = undefined;
    req_stor.waitFor(&wqv, io, &state_changes) catch |err| switch (err) {
        RequestStorage.WaitForError.SubsystemFail => {
            req_rec.error_lock.lockUncancelable(io);
            defer req_rec.error_lock.unlock(io);

            const conn_reset_server_msg = "Server unexpectedly closed the connection.";
            switch (req_rec.err.?) {
                RequestReceiver.SubsysError.Canceled => |e| return e,
                RequestReceiver.SubsysError.EndOfStream => {
                    log.err(conn_reset_server_msg, .{});
                    return QueryServerPublicSignKeyError.ConnectionResetByServer;
                },
                RequestReceiver.SubsysError.ReadFailed => switch (net_r.err.?) {
                    Stream.Reader.Error.ConnectionResetByPeer => {
                        log.err(conn_reset_server_msg, .{});
                        return QueryServerPublicSignKeyError.ConnectionResetByServer;
                    },
                    else => |re| {
                        log.err("Failed to read data from server due to error: {t}.", .{re});
                        return QueryServerPublicSignKeyError.StreamReadFailed;
                    },
                },
            }
        },
        else => return err,
    };

    std.debug.assert(state_changes == 1);

    const key_bytes = q_vec[0].result.by_resp_type.key_xchg.pub_sign_key;
    return SignAlgo.PublicKey.fromBytes(key_bytes) catch {
        log.warn("Queried key dumped: {b64}", .{key_bytes});
        return QueryServerPublicSignKeyError.ServerPublicSignKeyNonCanonical;
    };
}
