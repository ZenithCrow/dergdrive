const std = @import("std");

const sync = @import("dergdrive").proto.sync;
pub const InitError = sync.Chunk.CreateError;

const TransmitFileMsg = @This();

pub const NewMsgError = error{
    InsufficientBufferSpace,
    UnsupportedRequestType,
};

pub const non_payload_size = sync.header.header_size * 4 + sync.RequestChunk.content_size + sync.DestChunk.content_size;

msg_container: sync.SyncMessage,
rq_chunk: sync.RequestChunk,
dest_chunk: sync.DestChunk,
pld_chunk: sync.PayloadChunk,

pub fn init(buf: []u8) InitError!TransmitFileMsg {
    var tcm: TransmitFileMsg = .{
        .msg_container = .{ .msg_buf = buf },
        .rq_chunk = undefined,
        .dest_chunk = undefined,
        .pld_chunk = undefined,
    };

    var data_buf = tcm.msg_container.dataBuf();
    tcm.rq_chunk = try sync.Chunk.createChunk(sync.RequestChunk, data_buf);
    data_buf = data_buf[sync.header.header_size + sync.RequestChunk.content_size ..];

    tcm.dest_chunk = try sync.Chunk.createChunk(sync.DestChunk, data_buf);
    data_buf = data_buf[sync.header.header_size + sync.DestChunk.content_size ..];

    tcm.pld_chunk = try sync.Chunk.createChunk(sync.PayloadChunk, data_buf);

    tcm.msg_container.containMsgInSizeHeader();
    tcm.msg_container.updateHeader() catch unreachable;

    return tcm;
}

pub fn newMsg(self: *TransmitFileMsg, payload_size: u32, req_type: sync.RequestChunk.RequestType, id: sync.RequestChunk.IdT) NewMsgError![]u8 {
    if (non_payload_size + payload_size > self.msg_container.msg_buf.len)
        return NewMsgError.InsufficientBufferSpace;

    self.rq_chunk.id = id;
    self.rq_chunk.request_type = switch (req_type) {
        .chunk_update, .chunk_new => req_type,
        else => return NewMsgError.UnsupportedRequestType,
    };
    self.rq_chunk.resp_code = .resp_no_error;
    self.rq_chunk.write();

    self.pld_chunk.claimBuf(self.msg_container.msg_buf[non_payload_size .. non_payload_size + payload_size]);

    self.msg_container.containMsgInSizeHeader();
    self.msg_container.updateSizeHeader() catch unreachable;

    return self.pld_chunk.payload;
}

test "non-payload size matches" {
    var buf: [TransmitFileMsg.non_payload_size + 1024]u8 = undefined;

    const tfm: TransmitFileMsg = try .init(&buf);
    try std.testing.expectEqual(non_payload_size, try tfm.msg_container.getMsgSize());
}

test "newMsg payload size matches" {
    const payload_size = 1024;
    var buf: [TransmitFileMsg.non_payload_size + payload_size + 1024]u8 = undefined;

    var tfm: TransmitFileMsg = try .init(&buf);
    const pld_buf = try tfm.newMsg(payload_size, .chunk_update, 0);
    try std.testing.expectEqual(payload_size, pld_buf.len);
    try std.testing.expectEqual(payload_size + TransmitFileMsg.non_payload_size, try tfm.msg_container.getMsgSize());
}
