const std = @import("std");
const Thread = std.Thread;

const sync = @import("dergdrive").proto.sync;

const Cryptor = @import("Cryptor.zig");
const pipe_adapter = @import("pipe_adapter.zig");
const PrioRequest = @import("PrioRequest.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const log = std.log.scoped(.@"client/transmit/RequestSender");

const RequestSender = @This();

enc_file_reqs: *pipe_adapter.RequestPipeAdapter,
prio_request: PrioRequest,
writer: *std.Io.Writer,
req_stor: *RequestStorage,
send_task: ?std.Io.Future(std.Io.Cancelable!void) = null,
has_error: bool = false,
error_lock: std.Io.Mutex = .init,
error_cond: std.Io.Condition = .init,

pub fn init(enc_file_reqs: *pipe_adapter.RequestPipeAdapter, writer: *std.Io.Writer, req_stor: *RequestStorage, allocator: std.mem.Allocator) std.mem.Allocator.Error!RequestSender {
    return .{
        .enc_file_reqs = enc_file_reqs,
        .writer = writer,
        .prio_request = .{
            .request_buf = try .init(allocator),
        },
        .req_stor = req_stor,
    };
}

pub fn deinit(self: *RequestSender, allocator: std.mem.Allocator) void {
    self.prio_request.request_buf.deinit(allocator);
    self.send_task = null;
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
        return &self.prio_request.request_buf;
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

    {
        self.enc_file_reqs.idx_lock.lock(io) catch unreachable;
        defer self.enc_file_reqs.idx_lock.unlock(io);

        self.enc_file_reqs.avail_idx = @truncate(self.enc_file_reqs.cryptors.len);
    }

    self.enc_file_reqs.avail_cond.signal(io);
}

fn readBuf(self: *RequestSender, io: std.Io) std.Io.Cancelable![]u8 {
    {
        try self.enc_file_reqs.idx_lock.lock(io);
        defer self.enc_file_reqs.idx_lock.unlock(io);

        self.enc_file_reqs.avail_idx = pipe_adapter.RequestPipeAdapter.invalid_index;
    }

    var i: isize = @bitCast(self.enc_file_reqs.cryptors.len + 1);
    while (i >= 0) : (i -= 1) {
        const idx: u8 = if (@as(usize, @bitCast(i)) == self.enc_file_reqs.cryptors.len + 1) try self.waitUntilAvailable(io) else @truncate(@as(usize, @bitCast(i)));
        const req_buf_res = self.getReqBuf(idx) catch unreachable;

        try req_buf_res.chunk_buf.w_lock.lock(io);
        defer req_buf_res.chunk_buf.w_lock.unlock(io);

        if (req_buf_res.chunk_buf.fill_state == .full)
            return req_buf_res.chunk_buf.buf[0..req_buf_res.chunk_buf.data_len];
    }

    log.debug("idx: {d}", .{self.enc_file_reqs.avail_idx});

    unreachable;
}

fn finishReadBuf(self: *RequestSender, used_buf: []u8, io: std.Io) void {
    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    for (self.enc_file_reqs.cryptors) |*cryptor| {
        if (used_buf.ptr == cryptor.request_cbuf.chunk_buf.buf.ptr) {
            cryptor.request_cbuf.chunk_buf.setStateAndSignal(.empty, io) catch unreachable;
            return;
        }
    }

    if (used_buf.ptr == self.prio_request.request_buf.chunk_buf.buf.ptr)
        self.prio_request.request_buf.chunk_buf.setStateAndSignal(.empty, io) catch unreachable;
}

fn sendLoop(self: *RequestSender, io: std.Io) std.Io.Cancelable!void {
    while (true) {
        const req_buf = try self.readBuf(io);
        defer self.finishReadBuf(req_buf, io);

        self.writer.writeAll(req_buf) catch |err| {
            log.warn("Couldn' to writer writer due to error: {t}.", .{err});

            try self.error_lock.lock(io);
            defer self.error_lock.unlock(io);

            self.has_error = true;
            self.req_stor.broadcastSubsystemFail(io);

            // wait until acknowledged by the main thread which determines the error recoverability
            while (self.has_error == true)
                try self.error_cond.wait(io, &self.error_lock);

            continue;
        };
    }
}
