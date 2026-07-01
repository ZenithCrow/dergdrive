const std = @import("std");

const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;
const RootConf = dergdrive.conf.Conf;
const client = dergdrive.client;
const Conf = client.Conf;

const SecAuth = @This();

const log = std.log.scoped(.@"client/SecAuth");

pub const VerifyError = error{
    FirstTimeHost,
    OpenKnownHostsFailed,
    HostImpersonation,
} || crypt.SignAlgo.Signature.VerifyError;
pub const GetPubXchgKeySig = error{ MissingKeyPair, IdentityElementError, NonCanonicalError, KeyMismatchError, WeakPublicKeyError };
pub const GetSessionKeyError = error{IdentityElement};

dh_key_pair: crypt.KeyxchAlgo.KeyPair,
sign_key_pair: ?crypt.SignAlgo.KeyPair = null,
session_key: ?[crypt.AesAlgo.key_length]u8 = null,

pub fn init(key_pair: ?crypt.KeyxchAlgo.KeyPair, io: std.Io) SecAuth {
    const kp = if (key_pair) |k| k else crypt.KeyxchAlgo.KeyPair.generate(io);
    return .{ .dh_key_pair = kp };
}

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

    if (host) |h| {
        if (!std.mem.eql(u8, &pub_key, h))
            return VerifyError.HostImpersonation;
    } else return VerifyError.FirstTimeHost;
}

pub fn getDHXchgPubKey(self: *SecAuth, io: std.Io) [crypt.KeyxchAlgo.public_length]u8 {
    if (self.dh_key_pair) |pair| {
        return pair.public_key;
    }

    self.dh_key_pair = .generate(io);
    return self.dh_key_pair.?.public_key;
}

pub fn getPubXchgKeySig(self: SecAuth, io: std.Io) GetPubXchgKeySig!crypt.SignAlgo.Signature {
    if (self.sign_key_pair == null)
        return GetPubXchgKeySig.MissingKeyPair;

    var noise: [crypt.SignAlgo.noise_length]u8 = undefined;
    io.random(&noise);
    return self.sign_key_pair.?.sign(&self.dh_key_pair.public_key, noise);
}

pub fn getSessionKey(self: *SecAuth, dh_xchg_key: [crypt.KeyxchAlgo.public_length]u8) GetSessionKeyError![crypt.AesAlgo.key_length]u8 {
    const shared_scrt = try crypt.KeyxchAlgo.scalarmult(self.dh_key_pair.?.secret_key, dh_xchg_key);
    self.session_key = std.crypto.kdf.hkdf.HkdfSha256.extract("", &shared_scrt);
    return self.session_key.?;
}
