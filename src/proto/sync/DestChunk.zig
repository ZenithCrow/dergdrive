const std = @import("std");

const crypt = @import("dergdrive").crypt;

const Chunk = @import("Chunk.zig");

const DestChunk = @This();

pub const header_title = "dest";
pub const content_size = 2 * @sizeOf(u32) + crypt.NameHashAlgo.digest_length;

back_chunk: Chunk,
blk_id: [crypt.NameHashAlgo.digest_length]u8,
prev_len: u32,
offset: u32,

pub fn fromChunk(chunk: Chunk) DestChunk {
    return .{
        .back_chunk = chunk,
        .blk_id = chunk.data[0..crypt.NameHashAlgo.digest_length].*,
        .prev_len = std.mem.readInt(u32, chunk.data[crypt.NameHashAlgo.digest_length .. crypt.NameHashAlgo.digest_length + @sizeOf(u32)], .little),
        .offset = std.mem.readInt(u32, chunk.data[crypt.NameHashAlgo.digest_length + @sizeOf(u32) .. content_size], .little),
    };
}

pub fn justValues(blk_id: [crypt.NameHashAlgo.digest_length]u8, prev_len: u32, offset: u32) DestChunk {
    return .{
        .back_chunk = undefined,
        .blk_id = blk_id,
        .offset = offset,
        .prev_len = prev_len,
    };
}

pub fn write(self: DestChunk) void {
    std.mem.copyForwards(u8, self.back_chunk.data[0..crypt.NameHashAlgo.digest_length], &self.blk_id);
    std.mem.writeInt(u32, self.back_chunk.data[crypt.NameHashAlgo.digest_length .. crypt.NameHashAlgo.digest_length + @sizeOf(u32)], self.offset, .little);
    std.mem.writeInt(u32, self.back_chunk.data[crypt.NameHashAlgo.digest_length + @sizeOf(u32) .. content_size], self.offset, .little);
}

pub fn copyValues(self: *DestChunk, other: DestChunk) void {
    self.blk_id = other.blk_id;
    self.offset = other.offset;
    self.prev_len = other.prev_len;
}
