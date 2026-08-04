const std = @import("std");
const net = std.Io.net;
const Environ = std.process.Environ;

const client = @import("client");
const options = client.cli.options;
const server_opt = options.server;
const ctx_service = client.cli.ctx_service;
const connection_service = client.rxtx.connection_service;
const dergdrive = @import("dergdrive");
const util = dergdrive.util;
const cli = dergdrive.cli;
const Command = cli.Command;
const Option = cli.Option;
const port_opt = cli.options.port;
const RootConf = dergdrive.conf.Conf;
const parser = cli.parser;
const root_cmd_exec = cli.command_exec;
const crypt = dergdrive.crypt;

const log = std.log.scoped(.@"client/cli/commands/add-host");

pub const command: Command = .{
    .name = "add-host",
    .usage = "add-host",
    .desc = "Add a host to known hosts file and associate it with a given public key",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *const Environ.Map, gpa: std.mem.Allocator, io: std.Io) !void {
            return addHost(args, emap, gpa, io) catch |err| switch (err) {
                Command.ExecError.InvalidSyntax, Command.ExecError.TooFewArguments => |e| e,
                else => blk: {
                    log.err("Command failed due to error: {t}.", .{err});
                    break :blk cli.Command.ExecError.ReturnStatusFailure;
                },
            };
        }
    }.execFn,
    .options = &.{
        server_opt.option,
        port_opt.option,
        resolve_ip_opt,
        ignore_port_opt,
        user_pub_key_opt,
        force_opt,
    },
};

const resolve_ip_opt: Option = .{
    .long = "--resolve-ip",
    .short = 'i',
    .desc = "When provided with a hostname, associate the obtained public key with the resolved ip address instead of the hostname",
};

const ignore_port_opt: Option = .{
    .long = "--ignore-port",
    .short = 'g',
    .desc = "Ignore the given port and associate the obtained public key only with the hostname / ip address",
};

const user_pub_key_opt: Option = .{
    .long = "--public-key",
    .short = 'k',
    .desc = "Use public key (ED25519) provided by the user in base64 format (no connection to the server is made to evaluate the user given public key and compare it against the key potentially queried from the server)",
    .value = .{
        .eql_sign = true,
        .name = "PKEY",
    },
};

const force_opt: Option = .{
    .long = "--force",
    .short = 'f',
    .desc = "Override public sign key of a known host",
};

fn addHost(args: []const []const u8, emap: *const Environ.Map, gpa: std.mem.Allocator, io: std.Io) !void {
    const ctx: ctx_service.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);

    const hosts_file = ctx.conf.known_hosts.openOrCreate(false, io) catch |err| {
        log.err("Couldn't open known hosts file at '{f}' due to error: {t}.", .{ ctx.conf.known_hosts, err });
        return error.OpenKnownHostsFailed;
    };
    defer hosts_file.close(io);

    const hosts_buf = RootConf.getFileContent(hosts_file, gpa, io) catch |err| {
        log.err("Couldn't read known hosts file at '{f}' due to error: {t}.", .{ ctx.conf.known_hosts, err });
        return error.ReadKnownHostsFailed;
    };
    defer gpa.free(hosts_buf);

    const server_addr = root_cmd_exec.getCliThenConfigValue(ctx.env, server_opt.server_opt_name, ctx.args, server_opt.option) orelse {
        log.err(server_opt.option.notSetErrorMsg("Server address"), .{});
        return error.ServerAddressNotSet;
    };

    const port_str = root_cmd_exec.getCliThenConfigValue(ctx.env, port_opt.port_opt_name, ctx.args, port_opt.option);
    const ignore_port = parser.indexOfOption(args, ignore_port_opt.long, ignore_port_opt.short) != null;

    var addr_buf: [64]u8 = undefined;
    const address, const is_ip = if (net.IpAddress.parse(server_addr, 0)) |_| .{ server_addr, true } else |_| if (parser.indexOfOption(args, resolve_ip_opt.long, resolve_ip_opt.short) == null) .{ server_addr, false } else blk: {
        const host_name = net.HostName.init(server_addr) catch |err| {
            log.err(connection_service.unresolvable_host_msg, .{ server_addr, err });
            return error.UnresolvableHostName;
        };

        var canonical_name_buf: [net.HostName.max_len]u8 = undefined;
        var lookup_buffer: [32]net.HostName.LookupResult = undefined;
        var lookup_queue: std.Io.Queue(net.HostName.LookupResult) = .init(&lookup_buffer);

        const service_port = if (!ignore_port and port_str != null) std.fmt.parseInt(u16, port_str.?, 10) catch |err| {
            log.err(connection_service.port_num_parse_msg, .{err});
            return err;
        } else 6767; // use *random* port instead

        var lookup_future = io.async(net.HostName.lookup, .{
            host_name, io, &lookup_queue,
            net.HostName.LookupOptions{
                .canonical_name_buffer = &canonical_name_buf,
                .port = service_port,
            },
        });
        defer lookup_future.cancel(io) catch {};

        var canonical_name: net.HostName = undefined;
        const resolved_addr: net.IpAddress = while (lookup_queue.getOne(io)) |record| switch (record) {
            .address => |a| break a,
            .canonical_name => |n| {
                canonical_name = n;
                continue;
            },
        } else |err| switch (err) {
            error.Canceled => |e| return e,
            error.Closed => {
                lookup_future.await(io) catch |e| {
                    log.err("Lookup of hostname {s} (canonical form: {s}) failed due to error: {t}.", .{ server_addr, canonical_name.bytes, e });
                    return error.DnsLookupFailed;
                };

                // If we already got one result, it broke out of the while loop. The only way for `lookup_queue` to be closed is the lookup error above
                unreachable;
            },
        };

        // I assume errorneous response here could be unreachable since we already have a result... - place for pondering in the future
        lookup_future.cancel(io) catch {};

        var addr_w: std.Io.Writer = .fixed(&addr_buf);
        resolved_addr.format(&addr_w) catch unreachable;
        const with_port = addr_w.buffered();
        const port_idx = std.mem.findScalarLast(u8, with_port, ':').?;

        break :blk .{ with_port[0..port_idx], true };
    };

    const server_pkey: crypt.SignAlgo.PublicKey = if (parser.getAssociatedValue(args, user_pub_key_opt.long, user_pub_key_opt.short, user_pub_key_opt.value.?.eql_sign)) |user_pkey| blk: {
        const base64_len = 4 * @as(u32, @intFromFloat(@ceil(@as(f32, @floatFromInt(@as(u32, @truncate(crypt.SignAlgo.PublicKey.encoded_length)))) / 3)));
        if (user_pkey.len != base64_len) {
            log.err(
                "Provided ED25519 sign public key is expected to be {d} bytes wide ({d} base64 characters). Your input is {d} base64 characters.",
                .{ crypt.SignAlgo.PublicKey.encoded_length, base64_len, user_pkey.len },
            );
            return error.InvalidPublicKeyLength;
        }

        break :blk crypt.SignAlgo.PublicKey.fromBytes(user_pkey[0..crypt.SignAlgo.PublicKey.encoded_length].*) catch {
            log.err("Provided sign public key is not canonical for ED25519.", .{});
            return error.PublicKeyNonCanonical;
        };
    } else blk: {
        // returns error on missing port, no need to check it here
        var conn_details = try connection_service.getConnectionDetails(ctx);
        conn_details.host_name_str = address;

        const conn = try connection_service.connect(conn_details, io);
        break :blk connection_service.queryServerPublicSignKey(conn, gpa, io) catch |err| switch (err) {
            connection_service.QueryServerPublicSignKeyError.QueueFull => unreachable,
            connection_service.QueryServerPublicSignKeyError.ServerPublicSignKeyNonCanonical => |e| {
                log.err("Public sign key queried from server is not canonical for ED25519.", .{});
                return e;
            },
            else => return err,
        };
    };

    var ip_buf: [64]u8 = undefined;
    const final_addr = if (is_ip) blk: {
        var ip_w: std.Io.Writer = .fixed(&ip_buf);

        const ip_addr = net.IpAddress.parse(address, 0) catch unreachable;
        ip_addr.format(&ip_w) catch unreachable;
        const with_port = ip_w.buffered();
        const port_idx = std.mem.findScalarLast(u8, with_port, ':').?;

        break :blk with_port[0..port_idx];
    } else address;

    // leave some space for port
    var final_addr_w_port_buf: [net.HostName.max_len + 10]u8 = undefined;
    var fawp_w: std.Io.Writer = .fixed(&final_addr_w_port_buf);
    if (ignore_port) {
        fawp_w.writeAll(final_addr) catch unreachable;
    } else {
        const port_num = if (port_str) |p| std.fmt.parseInt(u16, p, 10) catch |err| {
            log.err(connection_service.port_num_parse_msg, .{err});
            return err;
        } else {
            log.err(port_opt.option.notSetErrorMsg("Server port"), .{});
            return error.ServerPortNotSet;
        };

        fawp_w.print("{s}:{d}", .{ final_addr, port_num }) catch unreachable;
    }

    const final_addr_w_port = fawp_w.buffered();

    const hosts_file_check_it: RootConf.KeyValueIterator = .init(hosts_buf);
    const kh_pub_key = RootConf.ConfFile.getKeyValueFromIter(hosts_file_check_it, final_addr_w_port);
    if (kh_pub_key != null) {
        if (cli.parser.indexOfOption(args, force_opt.long, force_opt.short) == null) {
            log.err("Host '{s}' is already known. To overwrite the trusted public sign key, use '--force' with this command.", .{address});
            return error.HostAlreadyKnown;
        }
    }

    // convert received key to base64 (guaranteed errorless)
    const encoder = std.base64.standard.Encoder;
    var server_pkey_b64_buf: [encoder.calcSize(crypt.SignAlgo.PublicKey.encoded_length)]u8 = undefined;
    const server_pkey_b64 = encoder.encode(&server_pkey_b64_buf, &server_pkey.toBytes());

    // compare the keys in base64 format
    const key_different = if (kh_pub_key) |khpk| !std.mem.eql(u8, khpk, server_pkey_b64) else true;
    if (key_different) {
        ctx.conf.known_hosts.setKeyValue(final_addr_w_port, server_pkey_b64, gpa, io) catch |err| {
            log.err("Failed to write public sign key of host '{s}' in known hosts file at {f} due to error: {t}.", .{ address, ctx.conf.known_hosts, err });
            return error.KnownHostsWriteFailed;
        };

        if (kh_pub_key) |khpk| {
            log.info("Successfully overwritten ED25519 public sign key of host '{s}' from old: {s} to new: {s}", .{ address, khpk, server_pkey_b64 });
        } else {
            const success_base_msg_start = "Successfully started trusting host '{s}' ";
            const success_base_msg_end = "with ED25519 public sign key: {s}";
            if (std.mem.eql(u8, address, server_addr)) {
                log.info(success_base_msg_start ++ success_base_msg_end, .{ address, server_pkey_b64 });
            } else log.info(success_base_msg_start ++ "(resolved to: {s}) " ++ success_base_msg_end, .{ server_addr, address, server_pkey_b64 });
        }
    } else log.warn("No change to host '{s}' was made because the queried ED25519 public sign key remains the same: {s}", .{ address, server_pkey_b64 });
}
