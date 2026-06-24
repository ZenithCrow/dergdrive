const std = @import("std");

const dergdrive = @import("dergdrive");
const crypt = dergdrive.crypt;

const Chunk = @import("Chunk.zig");

const KeyXchgChunk = @This();

pub const header_title = "kxcg";
pub const content_size = crypt.KeyxchAlgo.public_length + crypt.SignAlgo.Signature.encoded_length + crypt.SignAlgo.PublicKey.encoded_length;

back_chunk: Chunk,
pub_xchg_key: [crypt.KeyxchAlgo.public_length]u8,
signature: [crypt.SignAlgo.Signature.encoded_length]u8,
pub_sign_key: [crypt.SignAlgo.PublicKey.encoded_length]u8,

pub fn fromChunk(chunk: Chunk) KeyXchgChunk {
    return .{
        .back_chunk = chunk,
        .pub_xchg_key = chunk.data[0..crypt.KeyxchAlgo.public_length].*,
        .signature = chunk.data[crypt.KeyxchAlgo.public_length .. crypt.KeyxchAlgo.public_length + crypt.SignAlgo.Signature.encoded_length].*,
        .pub_sign_key = chunk.data[crypt.KeyxchAlgo.public_length + crypt.SignAlgo.Signature.encoded_length .. content_size].*,
    };
}

pub fn write(self: KeyXchgChunk) void {
    std.mem.copyForwards(u8, self.back_chunk.data[0..crypt.KeyxchAlgo.public_length], &self.pub_xchg_key);
    std.mem.copyForwards(u8, self.back_chunk.data[crypt.KeyxchAlgo.public_length .. crypt.KeyxchAlgo.public_length + crypt.SignAlgo.Signature.encoded_length], &self.signature);
    std.mem.copyForwards(u8, self.back_chunk.data[crypt.KeyxchAlgo.public_length + crypt.SignAlgo.Signature.encoded_length .. content_size], &self.pub_sign_key);
}
