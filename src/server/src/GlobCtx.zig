const std = @import("std");

const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;
const RootConf = dergdrive.conf.Conf;
const server = @import("server");
const Conf = server.Conf;

pub const InitError = error{GlobCtxInitFailed};
const GlobCtx = @This();

const log = std.log.scoped(.@"server/GlobCtx");

sign_key_pair: crypt.SignAlgo.KeyPair,

pub fn init(conf: Conf, gpa: std.mem.Allocator, io: std.Io) InitError!GlobCtx {
    const file_not_found_msg_base = "{s} sign key file '{f}' not found. For generating the key pair, see 'gen-sign' command.";
    const gen_err_msg_base = "Couldn't get contents of {s} sign key file '{f}' due to error: {t}.";
    const pub_key = conf.root_conf.getConf(conf.public_sign_key, gpa, io) catch |err| {
        switch (err) {
            RootConf.GetConfError.FileNotFound => log.err(file_not_found_msg_base, .{ "Public", conf.public_sign_key }),
            else => log.err(gen_err_msg_base, .{ "Public", conf.public_sign_key, err }),
        }
        return InitError.GlobCtxInitFailed;
    };
    defer gpa.free(pub_key);
    std.debug.assert(pub_key.len == crypt.SignAlgo.PublicKey.encoded_length);

    const priv_key = conf.root_conf.getConf(conf.private_sign_key, gpa, io) catch |err| {
        switch (err) {
            RootConf.GetConfError.FileNotFound => log.err(file_not_found_msg_base, .{ "Private", conf.private_sign_key }),
            else => log.err(gen_err_msg_base, .{ "Private", conf.private_sign_key, err }),
        }
        return InitError.GlobCtxInitFailed;
    };
    defer gpa.free(priv_key);
    std.debug.assert(priv_key.len == crypt.SignAlgo.SecretKey.encoded_length);

    const non_canon_err_msg_base = "{s} sign key read from file '{f}' is not canonical. For regenerating the sign key pair, see 'gen-sign' command.";
    const pk = crypt.SignAlgo.PublicKey.fromBytes(pub_key[0..crypt.SignAlgo.PublicKey.encoded_length].*) catch {
        log.err(non_canon_err_msg_base, .{ "Public", conf.public_sign_key });
        return InitError.GlobCtxInitFailed;
    };

    const sk = crypt.SignAlgo.SecretKey.fromBytes(priv_key[0..crypt.SignAlgo.SecretKey.encoded_length].*) catch {
        log.err(non_canon_err_msg_base, .{ "Private", conf.public_sign_key });
        return InitError.GlobCtxInitFailed;
    };

    return .{
        .sign_key_pair = .{
            .public_key = pk,
            .secret_key = sk,
        },
    };
}
