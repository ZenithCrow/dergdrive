const std = @import("std");

const sync = @import("dergdrive").proto.sync;
const TransmitFileMsg = sync.templates.TransmitFileMsg;

const ChunkBuffer = @import("ChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const RequestChunkBuffer = @This();

chunk_buf: ChunkBuffer,
sync_msg: sync.SyncMessage,
trns_msg: TransmitFileMsg,
req_id: ?sync.RequestChunk.IdT = null,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!RequestChunkBuffer {
    const chunk_buf: ChunkBuffer = .{ .buf = try allocator.alloc(u8, ChunkBuffer.chunk_size) };

    return .{
        .chunk_buf = chunk_buf,
        .sync_msg = .{ .msg_buf = chunk_buf.buf },
        .trns_msg = undefined,
    };
}

pub fn deinit(self: RequestChunkBuffer, allocator: std.mem.Allocator) void {
    allocator.free(self.chunk_buf.buf);
}

pub fn initTransmitFileMsg(self: *RequestChunkBuffer) TransmitFileMsg.InitError!void {
    self.trns_msg = try .init(self.sync_msg.msg_buf);
}
