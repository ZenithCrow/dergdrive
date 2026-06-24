const std = @import("std");

const proto = @import("dergdrive").proto;
const sync = proto.sync;
const TransmitChunkMsg = sync.templates.TransmitChunkMsg;

const ChunkBuffer = @import("ChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const RequestChunkBuffer = @This();

chunk_buf: ChunkBuffer,
sync_msg: sync.SyncMessage,
trns_msg: TransmitChunkMsg,
req_id: ?sync.RequestChunk.IdT = null,

pub fn init(allocator: std.mem.Allocator) std.mem.Allocator.Error!RequestChunkBuffer {
    const chunk_buf: ChunkBuffer = .{ .buf = try allocator.alloc(u8, proto.common.op_buf_size) };

    return .{
        .chunk_buf = chunk_buf,
        .sync_msg = .{ .msg_buf = chunk_buf.buf },
        .trns_msg = undefined,
    };
}

pub fn deinit(self: RequestChunkBuffer, allocator: std.mem.Allocator) void {
    allocator.free(self.chunk_buf.buf);
}

pub fn initTransmitFileMsg(self: *RequestChunkBuffer) TransmitChunkMsg.InitError!void {
    self.trns_msg = try .init(self.sync_msg.msg_buf);
}
