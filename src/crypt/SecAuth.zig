const std = @import("std");

const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;
const RootConf = dergdrive.conf.Conf;
const client = dergdrive.client;
const ClientConf = client.Conf;

const SecAuth = @This();

const log = std.log.scoped(.@"client/SecAuth");

pub const VerifyError = error{
    FirstTimeHost,
    OpenKnownHostsFailed,
    HostImpersonation,
} || crypt.SignAlgo.Signature.VerifyError;
pub const GetPubXchgKeySigError = error{ MissingKeyPair, IdentityElement, NonCanonical, KeyMismatch, WeakPublicKey };
pub const GetSessionKeyError = error{IdentityElement};

dh_key_pair: crypt.KeyxchAlgo.KeyPair,
sign_key_pair: ?crypt.SignAlgo.KeyPair = null,
session_key: ?[crypt.AesAlgo.key_length]u8 = null,

pub fn init(key_pair: ?crypt.KeyxchAlgo.KeyPair, io: std.Io) SecAuth {
    const kp = if (key_pair) |k| k else crypt.KeyxchAlgo.KeyPair.generate(io);
    return .{ .dh_key_pair = kp };
}

pub const HostIdentification = struct {
    ip_addr: std.Io.net.IpAddress,
    host_name: ?[]const u8,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        if (self.host_name) |hn| {
            try writer.print("'{s}' ({f})", .{ hn, self.ip_addr });
        } else try self.ip_addr.format(writer);
    }
};

pub fn verifyDHXchgPubKeyAuthenticity(
    conf: ClientConf,
    host_id: HostIdentification,
    signature: crypt.SignAlgo.Signature,
    pub_key: [crypt.SignAlgo.PublicKey.encoded_length]u8,
    dh_xchg_key: [crypt.KeyxchAlgo.public_length]u8,
    out_verified: *bool,
    gpa: std.mem.Allocator,
    io: std.Io,
) VerifyError!void {
    out_verified.* = false;

    const pub_key_canon = crypt.SignAlgo.PublicKey.fromBytes(pub_key) catch {
        log.warn("Queried key dumped: {b64}", .{pub_key});
        log.err("Couldn't proceed with verifying signature because the public sign key is not canonical.", .{});
        return VerifyError.NonCanonical;
    };
    try signature.verifyStrict(&dh_xchg_key, pub_key_canon);
    out_verified.* = true;

    const host_res: ClientConf.FindInKnownHostsResult = conf.findPubSignKeyInKnownHosts(host_id, pub_key_canon, gpa, io) catch |err| switch (err) {
        RootConf.GetConfError.FileNotFound => .{
            .last_match = null,
            .key_match = false,
        },
        else => {
            log.err("Failed to open known hosts file due to error: {t}.", .{err});
            return VerifyError.OpenKnownHostsFailed;
        },
    };
    defer host_res.deinit(gpa);

    if (host_res.last_match) |h| {
        if (!host_res.key_match) {
            log.info("Last matched host for {f}: {s}.", .{ host_id, h });
            return VerifyError.HostImpersonation;
        }
    } else return VerifyError.FirstTimeHost;
}

pub fn getDHXchgPubKey(self: *SecAuth) [crypt.KeyxchAlgo.public_length]u8 {
    return self.dh_key_pair.public_key;
}

pub fn getPubXchgKeySig(self: SecAuth, io: std.Io) GetPubXchgKeySigError!crypt.SignAlgo.Signature {
    if (self.sign_key_pair == null)
        return GetPubXchgKeySigError.MissingKeyPair;

    var noise: [crypt.SignAlgo.noise_length]u8 = undefined;
    io.random(&noise);
    return self.sign_key_pair.?.sign(&self.dh_key_pair.public_key, noise);
}

pub fn getSessionKey(self: *SecAuth, dh_xchg_key: [crypt.KeyxchAlgo.public_length]u8) GetSessionKeyError![crypt.AesAlgo.key_length]u8 {
    const shared_scrt = try crypt.KeyxchAlgo.scalarmult(self.dh_key_pair.secret_key, dh_xchg_key);
    self.session_key = std.crypto.kdf.hkdf.HkdfSha256.extract("", &shared_scrt);
    return self.session_key.?;
}
