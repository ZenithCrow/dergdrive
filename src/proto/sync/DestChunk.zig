const std = @import("std");

const crypt = @import("dergdrive").crypt;

const Chunk = @import("Chunk.zig");

const DestChunk = @This();

pub const header_title = "dest";
pub const content_size = 2 * @sizeOf(u32);

back_chunk: Chunk,
blk_id: u32,
offset: u32,

pub fn fromChunk(chunk: Chunk) DestChunk {
    return .{
        .back_chunk = chunk,
        .blk_id = std.mem.readInt(u32, chunk.data[0..@sizeOf(u32)], .little),
        .offset = std.mem.readInt(u32, chunk.data[@sizeOf(u32)..content_size], .little),
    };
}

pub fn write(self: DestChunk) void {
    std.mem.writeInt(u32, self.back_chunk.data[0..@sizeOf(u32)], self.blk_id, .little);
    std.mem.writeInt(u32, self.back_chunk.data[@sizeOf(u32)..content_size], self.offset, .little);
}

pub fn copyValues(self: *DestChunk, other: DestChunk) void {
    self.blk_id = other.blk_id;
    self.offset = other.offset;
}

/// distributes the length value over the smaller fields of this struct but doesn't write to the back_chunk (for that use `write` afterwards)
pub fn writeFileNewRequest(self: *DestChunk, length: u64) void {
    self.blk_id = @truncate(length);
    self.offset = @truncate(length >> @sizeOf(u32) * 8);
}

pub fn readNewFileRequest(self: DestChunk) u64 {
    return @as(u64, @intCast(self.blk_id)) | @as(u64, @intCast(self.offset)) << @sizeOf(u32) * 8;
}
