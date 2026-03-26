const std = @import("std");

const sync = @import("dergdrive").proto.sync;
const TransmitFileMsg = sync.templates.TransmitFileMsg;

const ChunkBuffer = @import("ChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const RequestChunkBuffer = @This();

chunk_buf: ChunkBuffer = .{ .buf_len = ChunkBuffer.chunk_size },
sync_msg: sync.SyncMessage = undefined,
trns_msg: TransmitFileMsg = undefined,
req_id: ?*sync.RequestChunk.IdT = null,

pub fn init(self: *RequestChunkBuffer) void {
    self.sync_msg.msg_buf = &self.chunk_buf.getBuf();
}

pub fn initTransmitFileMsg(self: *RequestChunkBuffer) void {
    self.trns_msg = .init(self.sync_msg.msg_buf);
}
