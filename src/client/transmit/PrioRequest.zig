const std = @import("std");

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const MultipleDestsChunkMsg = sync.templates.MultipleDestChunksMsg;
const TransactionAbortMsg = sync.templates.TransactionAbortMsg;
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const RequestChunk = sync.RequestChunk;

const ChunkBuffer = @import("ChunkBuffer.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");

const PrioRequest = @This();

pub const CreateReqError = error{Failed} || std.Io.Cancelable;

request_buf: RequestChunkBuffer,

fn createReq(self: *PrioRequest, io: std.Io, init_fn: anytype, args_wo_buf: anytype) CreateReqError!void {
    try self.request_buf.chunk_buf.waitUntilState(.empty, io);

    const msg = @call(.auto, init_fn, .{self.request_buf.chunk_buf.buf} ++ args_wo_buf) catch return CreateReqError.Failed;

    {
        self.request_buf.chunk_buf.w_lock.lockUncancelable(io);
        defer self.request_buf.chunk_buf.w_lock.unlock(io);

        self.request_buf.chunk_buf.data_len = msg.msg_container.getMsgSize() catch unreachable;
    }

    self.request_buf.sync_msg = msg.msg_container;

    try self.request_buf.chunk_buf.setStateAndSignal(.full, io);
}

pub fn createChunksDelReq(self: *PrioRequest, query: []const FileRecordMap.FileChunk, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    try self.createReq(io, MultipleDestsChunkMsg.init, .{ query, RequestChunk.RequestType.chunks_del, id });
}

pub fn createTransAbortReq(self: *PrioRequest, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    const old_p = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_p);

    try self.createReq(io, TransactionAbortMsg.init, .{id});
}
