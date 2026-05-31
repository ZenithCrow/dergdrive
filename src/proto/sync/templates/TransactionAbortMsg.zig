const std = @import("std");

const dergdrive = @import("dergdrive");
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const sync = dergdrive.proto.sync;
pub const Error = sync.Chunk.CreateError;

const TransactionAbortMsg = @This();

msg_container: sync.SyncMessage,

pub fn init(buf: []u8, id: sync.RequestChunk.IdT) Error!TransactionAbortMsg {
    var sync_msg: sync.SyncMessage = .{ .msg_buf = buf };
    const data_buf = sync_msg.dataBuf();

    var rq_chunk = try sync.Chunk.createChunk(sync.RequestChunk, data_buf);
    rq_chunk.id = id;
    rq_chunk.request_type = .trans_abort;
    rq_chunk.resp_code = .resp_no_error;
    rq_chunk.write();

    sync_msg.resetSizeHeader();
    sync_msg.updateHeader() catch unreachable;

    return .{
        .msg_container = sync_msg,
    };
}
