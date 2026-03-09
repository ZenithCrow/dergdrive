const std = @import("std");
const sync = @import("dergdrive").proto.sync;

const TransmitFileMsg = @This();

pub const InitError = sync.Chunk.CreateError;
pub const NewMsgError = error{
    InsufficientBufferSpace,
    UnsupportedRequestType,
};

pub const non_payload_size = sync.header.header_size * 4 + sync.RequestChunk.content_size + sync.DestChunk.content_size;

msg_container: sync.SyncMessage,
id_supply: *sync.RequestChunk.IdSupplier,
rq_chunk: sync.RequestChunk,
dest_chunk: sync.DestChunk,
pld_chunk: sync.PayloadChunk,

pub fn init(buf: []u8, id_supply: *sync.RequestChunk.IdSupplier) InitError!TransmitFileMsg {
    var tfm: TransmitFileMsg = .{
        .msg_container = .{ .msg_buf = buf },
        .id_supply = id_supply,
        .rq_chunk = undefined,
        .dest_chunk = undefined,
        .pld_chunk = undefined,
    };

    var data_buf = tfm.msg_container.dataBuf();
    tfm.rq_chunk = try sync.Chunk.createChunk(sync.RequestChunk, data_buf);
    data_buf = data_buf[sync.header.header_size + sync.RequestChunk.content_size ..];

    tfm.dest_chunk = try sync.Chunk.createChunk(sync.DestChunk, data_buf);
    data_buf = data_buf[sync.header.header_size + sync.DestChunk.content_size ..];

    tfm.pld_chunk = try sync.Chunk.createChunk(sync.PayloadChunk, data_buf);

    tfm.msg_container.resetSizeHeader();
    tfm.msg_container.updateHeader() catch unreachable;

    return tfm;
}

pub fn newMsg(self: *TransmitFileMsg, payload_size: u32, req_type: sync.RequestChunk.RequestType) NewMsgError![]u8 {
    if (non_payload_size + payload_size > self.msg_container.msg_buf.len)
        return NewMsgError.InsufficientBufferSpace;

    self.rq_chunk.id = self.id_supply.takeId();
    self.rq_chunk.request_type = switch (req_type) {
        .file_post, .file_new => req_type,
        else => return NewMsgError.UnsupportedRequestType,
    };
    self.rq_chunk.resp_code = .resp_no_error;
    self.rq_chunk.write();

    self.pld_chunk.claimBuf(self.msg_container.msg_buf[non_payload_size .. non_payload_size + payload_size]);

    self.msg_container.resetSizeHeader();
    self.msg_container.updateSizeHeader() catch unreachable;

    return self.pld_chunk.payload;
}

test "non-payload size matches" {
    var buf: [TransmitFileMsg.non_payload_size + 1024]u8 = undefined;
    var id_supply = sync.RequestChunk.IdSupplier{};

    const tfm: TransmitFileMsg = try .init(&buf, &id_supply);
    try std.testing.expectEqual(non_payload_size, try tfm.msg_container.getWrittenSize());
}

test "newMsg payload size matches" {
    const payload_size = 1024;
    var buf: [TransmitFileMsg.non_payload_size + payload_size + 1024]u8 = undefined;
    var id_supply = sync.RequestChunk.IdSupplier{};

    var tfm: TransmitFileMsg = try .init(&buf, &id_supply);
    const pld_buf = try tfm.newMsg(payload_size, .file_post);
    try std.testing.expectEqual(payload_size, pld_buf.len);
    try std.testing.expectEqual(payload_size + TransmitFileMsg.non_payload_size, try tfm.msg_container.getWrittenSize());
}
