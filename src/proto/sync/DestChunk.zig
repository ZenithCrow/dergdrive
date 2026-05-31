const std = @import("std");

const crypt = @import("dergdrive").crypt;

const Chunk = @import("Chunk.zig");

const DestChunk = @This();

pub const header_title = "dest";
pub const content_size = 2 * @sizeOf(u32) + @sizeOf(u64);

back_chunk: Chunk,
blk_id: u64,
prev_len: u32,
offset: u32,

pub const Query = struct {
    blk_id: u64,
    prev_len: u32,
    offset: u32,
};

pub fn fromChunk(chunk: Chunk) DestChunk {
    return .{
        .back_chunk = chunk,
        .blk_id = std.mem.readInt(u64, chunk.data[0..@sizeOf(u64)], .little),
        .prev_len = std.mem.readInt(u32, chunk.data[@sizeOf(u64) .. @sizeOf(u64) + @sizeOf(u32)], .little),
        .offset = std.mem.readInt(u32, chunk.data[@sizeOf(u64) + @sizeOf(u32) .. content_size], .little),
    };
}

pub fn write(self: DestChunk) void {
    std.mem.writeInt(u64, self.back_chunk.data[0..@sizeOf(u64)], self.blk_id, .little);
    std.mem.writeInt(u32, self.back_chunk.data[@sizeOf(u64) .. @sizeOf(u64) + @sizeOf(u32)], self.prev_len, .little);
    std.mem.writeInt(u32, self.back_chunk.data[@sizeOf(u64) + @sizeOf(u32) .. content_size], self.offset, .little);
}

pub fn valuesFromQuery(self: *DestChunk, query: Query) void {
    self.blk_id = query.blk_id;
    self.offset = query.offset;
    self.prev_len = query.prev_len;
}

pub fn copyValues(self: *DestChunk, other: DestChunk) void {
    self.blk_id = other.blk_id;
    self.offset = other.offset;
    self.prev_len = other.prev_len;
}
