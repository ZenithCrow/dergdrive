const std = @import("std");

const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;

const Chunk = @import("Chunk.zig");

const EncryptedPayloadChunk = @This();

pub const header_title = "encp";
pub const content_size = crypt.AesAlgo.nonce_length + crypt.AesAlgo.tag_length; // variable size

back_chunk: Chunk,
nonce: [crypt.AesAlgo.nonce_length]u8,
auth_tag: [crypt.AesAlgo.tag_length]u8,
enc_payload: []u8,

pub fn fromChunk(chunk: Chunk) EncryptedPayloadChunk {
    return .{
        .back_chunk = chunk,
        .nonce = chunk.data[0..crypt.AesAlgo.nonce_length],
        .auth_tag = chunk.data[crypt.AesAlgo.nonce_length .. crypt.AesAlgo.nonce_length + crypt.AesAlgo.tag_length],
        .enc_payload = chunk.data[content_size..],
    };
}

/// grows or shrinks the payload buffer in the context of the whole message buffer
/// it is up to the caller to ensure it doesn't grow out of bounds
pub fn claim(self: *EncryptedPayloadChunk, payload_len: usize) void {
    const data_ptr = self.back_chunk.data.ptr;
    self.back_chunk.data = data_ptr[0 .. content_size + payload_len];
    self.enc_payload = self.back_chunk.data[content_size..];
    self.back_chunk.updateSizeHeader();
}

pub fn unclaim(self: *EncryptedPayloadChunk) void {
    self.enc_payload = &.{};
    self.back_chunk.data = self.back_chunk.data[0..content_size];
    self.back_chunk.updateSizeHeader();
}
