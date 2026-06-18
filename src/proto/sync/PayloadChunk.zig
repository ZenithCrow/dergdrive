const std = @import("std");

const Chunk = @import("Chunk.zig");

const PayloadChunk = @This();

pub const header_title = "payd";
pub const content_size = 0; // variable size

back_chunk: Chunk,
payload: []u8,

pub fn fromChunk(chunk: Chunk) PayloadChunk {
    return .{
        .back_chunk = chunk,
        .payload = chunk.data,
    };
}

/// makes sense only when the provided buffer is a slice of the message data buffer
pub fn claimBuf(self: *PayloadChunk, buf: []u8) void {
    self.payload = buf;
    self.back_chunk.data = buf;
    self.back_chunk.updateSizeHeader();
}

pub fn unclaimBuf(self: *PayloadChunk) void {
    self.payload = &[_]u8{};
    self.back_chunk.data = &[_]u8{};
    self.back_chunk.updateSizeHeader();
}
