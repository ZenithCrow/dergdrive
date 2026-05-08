const std = @import("std");
pub const AesAlgo = std.crypto.aead.aes_gcm.Aes256Gcm;

pub const salt_lenght = 8;
pub const key_length = 32;
pub const nonce_auth_len = AesAlgo.nonce_length + AesAlgo.tag_length;

pub const key_path: []const u8 = "scrtkey";

pub const NameHashAlgo = struct {
    pub const digest_length = 8;
    pub const Algo = std.crypto.hash.blake2.Blake2b128;
};
