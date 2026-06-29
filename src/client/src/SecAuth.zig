const std = @import("std");

const client = @import("client");
const Conf = client.Conf;
const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;
const RootConf = dergdrive.conf.Conf;

const SecAuth = @This();

const log = std.log.scoped(.@"client/SecAuth");

pub const VerifyError = error{ FirstTimeHost, OpenKnownHostsFailed } || crypt.SignAlgo.Signature.VerifyError;
pub const GetSessionKeyError = error{ MissingKeyPair, IdentityElement };

dh_key_pair: ?crypt.KeyxchAlgo.KeyPair,
session_key: ?[crypt.AesAlgo.key_length]u8,

pub const init: SecAuth = .{
    .dh_key_pair = null,
    .session_key = null,
};

pub fn verifyDHXchgPubKeyAuthenticity(
    conf: Conf,
    address_name: []const u8,
    signature: crypt.SignAlgo.Signature,
    pub_key: [crypt.SignAlgo.PublicKey.encoded_length]u8,
    dh_xchg_key: [crypt.KeyxchAlgo.public_length]u8,
    out_verified: *bool,
    allocator: std.mem.Allocator,
    io: std.Io,
) VerifyError!void {
    out_verified.* = false;
    try signature.verifyStrict(&dh_xchg_key, try .fromBytes(pub_key));
    out_verified.* = true;

    const host = conf.root_conf.get(conf.known_hosts, address_name, allocator, io) catch |err| switch (err) {
        RootConf.GetConfError.FileNotFound => null,
        else => {
            log.err("Failed to open known hosts file due to error: {t}.", .{err});
            return VerifyError.OpenKnownHostsFailed;
        },
    };

    if (host == null)
        return VerifyError.FirstTimeHost;
}

pub fn getDHXchgPubKey(self: *SecAuth, io: std.Io) [crypt.KeyxchAlgo.public_length]u8 {
    if (self.dh_key_pair) |pair| {
        return pair.public_key;
    }

    self.dh_key_pair = .generate(io);
    return self.dh_key_pair.?.public_key;
}

pub fn getSessionKey(self: *SecAuth, dh_xchg_key: [crypt.KeyxchAlgo.public_length]u8) GetSessionKeyError![crypt.AesAlgo.key_length]u8 {
    if (self.dh_key_pair == null)
        return GetSessionKeyError.MissingKeyPair;

    const shared_scrt = try crypt.KeyxchAlgo.scalarmult(self.dh_key_pair.?.secret_key, dh_xchg_key);
    self.session_key = std.crypto.kdf.hkdf.HkdfSha256.extract("", &shared_scrt);
    return self.session_key.?;
}
