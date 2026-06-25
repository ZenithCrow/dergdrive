const std = @import("std");

const dergdrive = @import("dergdrive");
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const sync = dergdrive.proto.sync;
pub const Error = sync.Chunk.CreateError;

const TransactionAbortMsg = @This();

msg_container: sync.SyncMessage,

pub fn init(buf: []u8, id: sync.RequestChunk.IdT) Error!TransactionAbortMsg {
    var sync_msg: sync.SyncMessage = .{ .msg_buf = buf };
    const data_buf = try sync_msg.initRequest(.trans_abort, id);
    _ = sync.Chunk.createChunk(sync.BreakChunk, data_buf) catch {};

    sync_msg.containMsgInSizeHeader();
    sync_msg.updateHeader() catch unreachable;

    return .{
        .msg_container = sync_msg,
    };
}
