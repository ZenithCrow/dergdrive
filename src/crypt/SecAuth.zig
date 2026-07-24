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

    const pub_key_canon: crypt.SignAlgo.PublicKey = try .fromBytes(pub_key);
    try signature.verifyStrict(&dh_xchg_key, pub_key_canon);
    out_verified.* = true;

    const host_res: ClientConf.FindInKnownHostsResult = conf.findPubSignKeyInKnownHosts(host_id, pub_key_canon, gpa, io) catch |err| switch (err) {
        RootConf.GetConfError.FileNotFound => .{
            .last_match = null,
            .last_match_key = null,
            .key_match = false,
        },
        else => return VerifyError.OpenKnownHostsFailed,
    };
    defer host_res.deinit(gpa);

    if (host_res.last_match) |h| {
        std.debug.assert(host_res.last_match_key != null);
        if (!host_res.key_match) {
            log.warn("Last matched host for {f}: {s}. Saved key dumped: {b64}", .{ host_id, h, host_res.last_match_key.?.toBytes() });
            return VerifyError.HostImpersonation;
        }
    } else return VerifyError.FirstTimeHost;
}

pub fn verifyDHXchgPubKeyAuthenticityLog(
    conf: ClientConf,
    host_id: HostIdentification,
    signature: crypt.SignAlgo.Signature,
    pub_key: [crypt.SignAlgo.PublicKey.encoded_length]u8,
    dh_xchg_key: [crypt.KeyxchAlgo.public_length]u8,
    out_verified: *bool,
    gpa: std.mem.Allocator,
    io: std.Io,
) VerifyError!void {
    verifyDHXchgPubKeyAuthenticity(conf, host_id, signature, pub_key, dh_xchg_key, out_verified, gpa, io) catch |err| {
        log.warn("Queried key dumped: {b64}", .{pub_key});
        switch (err) {
            VerifyError.NonCanonical => log.err("Couldn't proceed with verifying signature because the public sign key is not canonical.", .{}),
            VerifyError.FirstTimeHost => log.warn("Authenticity of this host can't be verified, since it is not included in known hosts. Tread carefully. To add this host, use the 'add-host' command or edit the known hosts file.", .{}),
            VerifyError.HostImpersonation => log.err("The public key of this known host is different from the one it currently presents itself with. Tread extra carefully, someone might be trying to impersonate this host. If you are 100% sure the public key has changed, use the 'add-host' command with '--force' or edit the known hosts file.", .{}),
            VerifyError.OpenKnownHostsFailed => log.err("Couldn't open known hosts file due to error: {t} and thus the authenticity of this host can't be verified even though the signature itself was successfully verified. Tread carefully.", .{err}),
            VerifyError.SignatureVerificationFailed => log.err("Failed to verify host signature. This is a huge security risk. Tread extra carefully.", .{}),
            else => log.err("Couldn't verify host signature due to error: {t}. Tread extra carefully.", .{err}),
        }

        return err;
    };
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
