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

const PrioRequest = @This();

const log = std.log.scoped(.@"client/rxtx/PrioRequest");

pub const CreateReqError = error{Failed} || std.Io.Cancelable;
pub const SendError = sync.Chunk.ReadError || std.Io.Cancelable;

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

pub fn chunksDelReq(self: *PrioRequest, query: []const FileRecordMap.FileChunk, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    try self.createReq(io, MultipleDestsChunkMsg.init, .{ query, RequestChunk.RequestType.chunks_del, id });
}

pub fn unitAbortReq(self: *PrioRequest, req_ids: []const RequestChunk.IdT, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    try self.createReq(io, UnitAbortMsg.init, .{ req_ids, id });
}

pub fn transAbortReq(self: *PrioRequest, id: RequestChunk.IdT, io: std.Io) CreateReqError!void {
    const old_p = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_p);

    try self.createReq(io, TransactionAbortMsg.init, .{id});
}

fn waitForEmptyBuf(self: *PrioRequest, io: std.Io) std.Io.Cancelable![]u8 {
    try self.request_buf.chunk_buf.waitUntilState(.empty, io);
    return self.request_buf.chunk_buf.buf;
}

fn signal(self: *PrioRequest, io: std.Io) void {
    const req_sender: *RequestSender = @fieldParentPtr("prio_request", self);
    req_sender.signalPriorityRequest(io);
}

pub fn sendMsg(self: *PrioRequest, msg: sync.SyncMessage, io: std.Io) SendError!void {
    {
        self.request_buf.chunk_buf.w_lock.lockUncancelable(io);
        defer self.request_buf.chunk_buf.w_lock.unlock(io);

        self.request_buf.chunk_buf.data_len = try msg.getMsgSize();
        log.debug("msg size: {d}", .{self.request_buf.chunk_buf.data_len});
    }

    self.request_buf.sync_msg = msg;
    try self.request_buf.chunk_buf.setStateAndSignal(.full, io);
    self.signal(io);
}

pub fn sendVersion(self: *PrioRequest, version: ?std.SemanticVersion, io: std.Io) std.Io.Cancelable!void {
    log.debug("sendVersion waiting for empty buffer", .{});
    var msg_snake: MsgChunkSnake = .fromBuf(try self.waitForEmptyBuf(io));
    const msg = msg_snake.version(version).finalize() catch unreachable;
    self.sendMsg(msg, io) catch |err| switch (err) {
        std.Io.Cancelable.Canceled => |e| return e,
        else => unreachable,
    };
}

pub fn sendKeyXchg(self: *PrioRequest, pub_key: [dergdrive.crypt.KeyxchAlgo.public_length]u8, io: std.Io) std.Io.Cancelable!void {
    log.debug("sendKeyXchg waiting for empty buffer", .{});
    var msg_snake: MsgChunkSnake = .fromBuf(try self.waitForEmptyBuf(io));
    const msg = msg_snake.keyxchg(pub_key, null, null).finalize() catch unreachable;
    self.sendMsg(msg, io) catch |err| switch (err) {
        std.Io.Cancelable.Canceled => |e| return e,
        else => unreachable,
    };
}
