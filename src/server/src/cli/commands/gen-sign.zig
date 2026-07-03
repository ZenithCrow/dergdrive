const std = @import("std");
const net = std.Io.net;

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const Option = cli.Option;
const server = @import("server");
const server_cli = server.cli;
const command_exec = server_cli.command_exec;
const root_cmd_exec = cli.command_exec;
const ConnectionWorker = server.rxtx.ConnectionWorker;
const NetAcceptor = server.rxtx.NetAcceptor;
const GlobCtx = server.GlobCtx;
const RootConf = dergdrive.conf.Conf;
const parser = cli.parser;
const crypt = dergdrive.crypt;

const log = std.log.scoped(.@"server/cli/commands/gen-sign");

pub const command: cli.Command = .{
    .name = "gen-sign",
    .usage = "gen-sign [OPTIONS]",
    .desc = "Generate a sign key pair for the server",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *std.process.Environ.Map, gpa: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            return genSign(args, emap, gpa, io) catch |err| switch (err) {
                cli.Command.ExecError.InvalidSyntax => @errorCast(err),
                cli.Command.ExecError.TooFewArguments => @errorCast(err),
                else => blk: {
                    log.err("Command failed due to error: {t}.", .{err});
                    break :blk cli.Command.ExecError.ReturnStatusFailure;
                },
            };
        }
    }.execFn,
    .options = &.{force_opt},
};

const force_opt: Option = .{
    .long = "--force",
    .short = 'f',
    .desc = "Force overwrite of existing key pair. This will break trust with clients that have added this server's public key to their known hosts.",
};

fn genSign(args: []const []const u8, emap: *std.process.Environ.Map, gpa: std.mem.Allocator, io: std.Io) !void {
    const ctx: command_exec.ParamContext = try .init(args, emap, gpa, io);
    defer ctx.deinit(gpa);

    const existing_pub_key: ?[]const u8 = ctx.conf.root_conf.getConf(ctx.conf.public_sign_key, gpa, io) catch |err| switch (err) {
        RootConf.GetConfError.FileNotFound => null,
        else => {
            log.err("Failed to get contents of public sign key file '{f}' due to error: {t}", .{ ctx.conf.public_sign_key, err });
            return error.FailedToGetPublicSignKey;
        },
    };
    defer if (existing_pub_key) |pk| gpa.free(pk);

    const existing_priv_key: ?[]const u8 = ctx.conf.root_conf.getConf(ctx.conf.private_sign_key, gpa, io) catch |err| switch (err) {
        RootConf.GetConfError.FileNotFound => null,
        else => {
            log.err("Failed to get contents of private sign key file '{f}' due to error: {t}", .{ ctx.conf.private_sign_key, err });
            return error.FailedToGetPrivateSignKey;
        },
    };
    defer if (existing_priv_key) |pk| gpa.free(pk);

    if (existing_pub_key != null or existing_priv_key != null) {
        if (parser.indexOfOption(args, force_opt.long, force_opt.short) == null) {
            log.err("Found existing sign key pair at '{f}' and '{f}'. To regenerate it, use '--force'.", .{ ctx.conf.public_sign_key, ctx.conf.private_sign_key });
            return error.ExistingSignKeyPairFound;
        } else {
            log.warn("You are trying to overwrite the existing sign pair. Doing so will result in clients losing trust in this server if they have added the server's public key to their known hosts.", .{});
            var w_buf: [64]u8 = undefined;
            var stdout_w = std.Io.File.stdout().writerStreaming(io, &w_buf);
            try stdout_w.interface.writeAll("Are you sure you want to overwrite the existing sign key pair? [y/N]: ");
            try stdout_w.flush();

            var r_buf: [64]u8 = undefined;
            var stdin_r = std.Io.File.stdin().readerStreaming(io, &r_buf);
            var answer_buf: [2]u8 = undefined;
            var answer_w = std.Io.Writer.fixed(&answer_buf);
            const bytes_streamed = stdin_r.interface.streamDelimiter(&answer_w, '\n') catch |err| switch (err) {
                error.EndOfStream => return error.InvalidInput,
                else => return err,
            };

            if (bytes_streamed == 0 or answer_buf[0] != 'y')
                return error.CancelledByUser;
        }
    }

    log.info("Generating sign key pair...", .{});

    const sign_key_pair: crypt.SignAlgo.KeyPair = .generate(io);
    ctx.conf.root_conf.writeConfFile(ctx.conf.public_sign_key, true, &sign_key_pair.public_key.toBytes(), gpa, io) catch |err| {
        log.err("Couldn't write public sign key due to error: {t}", .{err});
        return error.WritePubSignKeyFailed;
    };

    ctx.conf.root_conf.writeConfFile(ctx.conf.private_sign_key, true, &sign_key_pair.secret_key.toBytes(), gpa, io) catch |err| {
        log.err("Couldn't write private sign key due to error: {t}", .{err});
        return error.WritePrivSignKeyFailed;
    };

    log.info("Successfully written sign key pair.", .{});
}
