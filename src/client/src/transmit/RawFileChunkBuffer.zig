const std = @import("std");

const sync = @import("dergdrive").proto.sync;

const ChunkBuffer = @import("ChunkBuffer.zig");
const Cryptor = @import("Cryptor.zig");
const RequestStorage = @import("RequestStorage.zig");

const RawFileChunkBuffer = @This();

pub const buf_size = ChunkBuffer.chunk_size - (Cryptor.enc_add_info_len + sync.templates.TransmitChunkMsg.non_payload_size);

chunk_buf: ChunkBuffer,
req_id: ?sync.RequestChunk.IdT = null,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!RawFileChunkBuffer {
    return .{
        .chunk_buf = .{ .buf = try allocator.alloc(u8, buf_size) },
    };
}

pub fn deinit(self: RawFileChunkBuffer, allocator: std.mem.Allocator) void {
    allocator.free(self.chunk_buf.buf);
}
