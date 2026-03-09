const std = @import("std");
const header = @import("header.zig");
const Chunk = @import("Chunk.zig");
const RequestChunk = @import("RequestChunk.zig");

const SyncMessage = @This();

pub const header_title = "dsnc";

// the reserved buffer for this sync message, including header
msg_buf: []u8,

pub fn iterFromBuf(buffer: []u8) Chunk.ReadError!Chunk.Iterator {
    const chunk = try Chunk.readChunk(buffer);
    return .{ .buffer = chunk.data };
}

pub fn dataBuf(self: SyncMessage) []u8 {
    return self.msg_buf[header.header_size..];
}

/// the total size of data in the message excluding the size header
pub fn dataSize(self: SyncMessage) Chunk.ReadError!header.DataLenT {
    var chunk_iter = try iterFromBuf(self.msg_buf);
    var total_size: header.DataLenT = 0;

    while (chunk_iter.next() catch return total_size) |chunk| {
        total_size += chunk.getWrittenSize();
    }

    return total_size;
}

/// the total size of the message including header and data
pub inline fn getWrittenSize(self: SyncMessage) Chunk.ReadError!header.DataLenT {
    return header.header_size + try self.dataSize();
}

pub inline fn readWrittenSize(self: SyncMessage) header.DataLenT {
    return std.mem.readInt(header.DataLenT, self.msg_buf[header.header_title_size..header.header_size], .little);
}

inline fn writeSize(self: SyncMessage, size: header.DataLenT) void {
    std.mem.writeInt(header.DataLenT, self.msg_buf[header.header_title_size..header.header_size], size, .little);
}

pub inline fn updateSizeHeader(self: SyncMessage) Chunk.ReadError!void {
    self.writeSize(try self.dataSize());
}

pub inline fn resetSizeHeader(self: SyncMessage) void {
    self.writeSize(self.msg_buf.len - header.header_size);
}

pub fn updateHeader(self: SyncMessage) Chunk.ReadError!void {
    std.mem.copyForwards(u8, self.msg_buf[0..header.header_title_size], header_title);
    try self.updateSizeHeader();
}
