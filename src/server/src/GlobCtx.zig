const std = @import("std");

const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;
const RootConf = dergdrive.conf.Conf;
const server = @import("server");
const Conf = server.Conf;

pub const InitError = RootConf.GetConfError || error{NonCanonical};
const GlobCtx = @This();

const log = std.log.scoped(.@"server/GlobCtx");

sign_key_pair: crypt.SignAlgo.KeyPair,

pub fn init(conf: Conf, gpa: std.mem.Allocator, io: std.Io) InitError!GlobCtx {
    const pub_key = try conf.root_conf.getConf(conf.public_sign_key, gpa, io);
    defer gpa.free(pub_key);
    std.debug.assert(pub_key.len == crypt.SignAlgo.PublicKey.encoded_length);

    const priv_key = try conf.root_conf.getConf(conf.public_sign_key, gpa, io);
    defer gpa.free(priv_key);
    std.debug.assert(priv_key.len == crypt.SignAlgo.SecretKey.encoded_length);

    return .{
        .sign_key_pair = .{
            .public_key = try .fromBytes(pub_key[0..crypt.SignAlgo.PublicKey.encoded_length].*),
            .secret_key = try .fromBytes(priv_key[0..crypt.SignAlgo.SecretKey.encoded_length].*),
        },
    };
}
