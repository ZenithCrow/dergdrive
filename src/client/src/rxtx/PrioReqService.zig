const std = @import("std");

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const MultipleDestsChunkMsg = sync.templates.MultipleDestChunksMsg;
const TransactionAbortMsg = sync.templates.TransactionAbortMsg;
const UnitAbortMsg = sync.templates.UnitAbortMsg;
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const RequestChunk = sync.RequestChunk;
const MsgChunkSnake = sync.MsgChunkSnake;

const ChunkBuffer = @import("ChunkBuffer.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");
const RequestSender = @import("RequestSender.zig");

const PrioReqService = @This();

const log = std.log.scoped(.@"client/rxtx/PrioRequest");

pub const CreateReqError = error{Failed} || std.Io.Cancelable;

req_sender: *RequestSender,

fn createReq(self: PrioReqService, io: std.Io, init_fn: anytype, args_wo_buf: anytype) CreateReqError!void {
    try self.req_sender.prio_request.request_buf.chunk_buf.waitUntilState(.empty, io);

    const msg = @call(.auto, init_fn, .{self.req_sender.prio_request.request_buf.chunk_buf.buf} ++ args_wo_buf) catch return CreateReqError.Failed;

    {
        self.req_sender.prio_request.request_buf.chunk_buf.w_lock.lockUncancelable(io);
        defer self.req_sender.prio_request.request_buf.chunk_buf.w_lock.unlock(io);

        self.req_sender.prio_request.request_buf.chunk_buf.data_len = msg.msg_container.getMsgSize() catch unreachable;
    }

    self.req_sender.prio_request.request_buf.sync_msg = msg.msg_container;

    try self.req_sender.prio_request.request_buf.chunk_buf.setStateAndSignal(.full, io);
}

pub fn chunksDelReq(self: PrioReqService, query: []const FileRecordMap.FileChunk, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    try self.createReq(io, MultipleDestsChunkMsg.init, .{ query, RequestChunk.RequestType.chunks_del, id });
}

pub fn unitAbortReq(self: PrioReqService, req_ids: []const RequestChunk.IdT, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    try self.createReq(io, UnitAbortMsg.init, .{ req_ids, id });
}

pub fn transAbortReq(self: PrioReqService, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    const old_p = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_p);

    try self.createReq(io, TransactionAbortMsg.init, .{id});
}

pub fn sendVersion(self: PrioReqService, version: ?std.SemanticVersion, io: std.Io) std.Io.Cancelable!void {
    log.debug("sendVersion waiting for empty buffer", .{});
    var msg_snake: MsgChunkSnake = .fromBuf(try self.req_sender.prio_request.waitForEmptyBuf(io));
    const msg = msg_snake.version(version).finalize() catch unreachable;
    self.req_sender.prio_request.sendMsg(msg, io) catch |err| switch (err) {
        std.Io.Cancelable.Canceled => |e| return e,
        else => unreachable,
    };
}

pub fn sendKeyXchg(self: PrioReqService, pub_key: [dergdrive.crypt.KeyxchAlgo.public_length]u8, io: std.Io) std.Io.Cancelable!void {
    log.debug("sendKeyXchg waiting for empty buffer", .{});
    var msg_snake: MsgChunkSnake = .fromBuf(try self.req_sender.prio_request.waitForEmptyBuf(io));
    const msg = msg_snake.keyxchg(pub_key, null, null).finalize() catch unreachable;
    self.req_sender.prio_request.sendMsg(msg, io) catch |err| switch (err) {
        std.Io.Cancelable.Canceled => |e| return e,
        else => unreachable,
    };
}
