const std = @import("std");
const Environ = std.process.Environ;

const client = @import("client");
const options = client.cli.options;
const server_opt = options.server;
const service = client.cli.service;
const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const Command = cli.Command;
const Option = cli.Option;
const port_opt = cli.options.port;
const RootConf = dergdrive.conf.Conf;

const log = std.log.scoped(.@"client/cli/commands/add-host");

pub const command: Command = .{
    .name = "add-host",
    .usage = "add-host",
    .desc = "Add a host to known hosts file and associate it with a given public key",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *const Environ.map, gpa: std.mem.Allocator, io: std.Io) !void {
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
    },
};

const resolve_ip_opt: Option = .{
    .long = "--resolve-ip",
    .short = 'i',
    .desc = "When provided with a host name, associate the obtained public key with the resolved ip address instead of the host name",
};

const ignore_port_opt: Option = .{
    .long = "--ignore-port",
    .short = 'g',
    .desc = "Ignore the given port and associate the obtained public key only with the host name / ip address",
};

const user_pub_key_opt: Option = .{
    .long = "--public-key",
    .short = 'k',
    .desc = "Use public key provided by the user in base64 format (no connection to the server is made to evaluate the user given public key)",
};

fn addHost(args: []const []const u8, emap: *const Environ.Map, gpa: std.mem.Allocator, io: std.Io) !void {
    const ctx: service.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);

    const hosts_file = ctx.conf.root_conf.openOrCreateConfFile(ctx.conf.known_hosts, false, gpa, io) catch |err| {
        log.err("Couldn't open known hosts file at '{f}' due to error: {t}.", .{ ctx.conf.known_hosts, err });
        return error.OpenKnownHostsFailed;
    };
    defer hosts_file.close(io);

    const hosts_buf = RootConf.getFileContent(hosts_file, gpa, io) catch |err| {
        log.err("Couldn't read known hosts file at '{f}' due to error: {t}.", .{ ctx.conf.known_hosts, err });
        return error.ReadKnownHostsFailed;
    };
    defer gpa.free(hosts_buf);

    var iter: RootConf.KeyValueIterator = .init(hosts_buf);
}
