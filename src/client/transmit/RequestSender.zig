const std = @import("std");
const Thread = std.Thread;

const sync = @import("dergdrive").proto.sync;
//const TcpClient = @import("znetw").TcpClient;

const Cryptor = @import("Cryptor.zig");
const pipe_adapter = @import("pipe_adapter.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");

const AtomicBool = std.atomic.Value(bool);
const RequestSender = @This();

//tcp_cli: *TcpClient,
id_supply: *sync.RequestChunk.IdSupplier,
enc_file_reqs: *pipe_adapter.RequestPipeAdapter,
prio_request: RequestChunkBuffer,
send_task: ?std.Io.Future(std.Io.Cancelable!void) = null,

pub fn init(id_supply: *sync.RequestChunk.IdSupplier, enc_file_reqs: *pipe_adapter.RequestPipeAdapter, allocator: std.mem.Allocator) std.mem.Allocator.Error!RequestSender {
    return .{
        .id_supply = id_supply,
        .enc_file_reqs = enc_file_reqs,
        .prio_request = try .init(allocator),
    };
}

pub fn start(self: *RequestSender, io: std.Io) std.Io.ConcurrentError!void {
    std.debug.assert(self.send_task == null);

    self.send_task = try io.concurrent(sendLoop, .{ self, io });
}

pub fn stop(self: *RequestSender, io: std.Io) void {
    if (self.send_task) |*t| t.cancel(io) catch {};
}

const GetReqBufError = error{InvalidIndex};

/// index after the last cryptor index is associated with the prioritized request
fn getReqBuf(self: *RequestSender, idx: u8) GetReqBufError!*RequestChunkBuffer {
    const num_cryptors = self.enc_file_reqs.cryptors.len;

    if (idx < num_cryptors) {
        return &self.enc_file_reqs.cryptors[idx].request_cbuf;
    } else if (idx == num_cryptors) {
        return &self.prio_request;
    } else return GetReqBufError.InvalidIndex;
}

fn waitUntilAvailable(self: *RequestSender, io: std.Io) std.Io.Cancelable!u8 {
    try self.enc_file_reqs.idx_lock.lock(io);
    defer self.enc_file_reqs.idx_lock.unlock(io);

    while (self.enc_file_reqs.avail_idx == pipe_adapter.RequestPipeAdapter.invalid_index)
        try self.enc_file_reqs.avail_cond.wait(io, &self.enc_file_reqs.idx_lock);

    const idx = self.enc_file_reqs.avail_idx;
    self.enc_file_reqs.avail_idx = pipe_adapter.RequestPipeAdapter.invalid_index;
    return idx;
}

pub fn signalPriorityRequest(self: *RequestSender, io: std.Io) void {
    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    self.enc_file_reqs.idx_lock.lock(io) catch unreachable;
    defer self.enc_file_reqs.idx_lock.unlock(io);

    self.enc_file_reqs.avail_idx = @truncate(self.enc_file_reqs.cryptors.len);
    self.enc_file_reqs.avail_cond.signal(io);
}

fn readBuf(self: *RequestSender, io: std.Io) std.Io.Cancelable![]u8 {
    {
        try self.enc_file_reqs.idx_lock.lock(io);
        defer self.enc_file_reqs.idx_lock.unlock(io);

        self.enc_file_reqs.avail_idx = pipe_adapter.RequestPipeAdapter.invalid_index;
    }

    for (0..self.enc_file_reqs.cryptors.len + 2) |i| {
        const idx: u8 = if (i == self.enc_file_reqs.cryptors.len + 1) try self.waitUntilAvailable(io) else @truncate(i);
        const req_buf_res = self.getReqBuf(idx) catch unreachable;

        try req_buf_res.chunk_buf.w_lock.lock(io);
        defer req_buf_res.chunk_buf.w_lock.unlock(io);

        if (req_buf_res.chunk_buf.empty == .full)
            return req_buf_res.chunk_buf.buf[0..req_buf_res.chunk_buf.data_len];
    }

    unreachable;
}

fn finishReadBuf(self: *RequestSender, used_buf: []u8, io: std.Io) void {
    for (self.enc_file_reqs.cryptors) |*cryptor| {
        if (used_buf.ptr == cryptor.request_cbuf.chunk_buf.buf.ptr) {
            cryptor.request_cbuf.chunk_buf.signalState(.empty, io);
            return;
        }
    }

    if (used_buf.ptr == self.prio_request.chunk_buf.buf.ptr)
        self.prio_request.chunk_buf.signalState(.empty, io);
}

fn sendLoop(self: *RequestSender, io: std.Io) std.Io.Cancelable!void {
    while (true) {
        const req_buf = try self.readBuf(io);
        defer self.finishReadBuf(req_buf, io);

        // self.tcp_cli.sendAll(req_buf) catch {
        //     //  TODO: handle error
        //     std.log.err("sending file failed", .{});
        // };
    }
}
