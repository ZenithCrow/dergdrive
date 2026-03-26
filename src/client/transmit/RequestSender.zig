const std = @import("std");
const Thread = std.Thread;

const sync = @import("dergdrive").proto.sync;
const TcpClient = @import("znetw").TcpClient;

const Cryptor = @import("Cryptor.zig");
const pipe_adapter = @import("pipe_adapter.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");

const AtomicBool = std.atomic.Value(bool);
const RequestSender = @This();

tcp_cli: *TcpClient,
id_supply: sync.RequestChunk.IdSupplier = .{},
enc_file_reqs: *pipe_adapter.RequestPipeAdapter,
prio_request: RequestChunkBuffer = undefined,
running: AtomicBool = .init(false),
send_th: Thread = undefined,

pub fn init(self: *RequestSender) void {
    self.prio_request = .init(&self.id_supply);
}

pub fn start(self: *RequestSender) Thread.SpawnError!void {
    self.running.store(true, .release);
    errdefer self.running.store(false, .release);

    self.send_th = try Thread.spawn(.{}, sendLoop, self);
}

pub fn stop(self: *RequestSender) void {
    if (self.running.load(.acquire)) {
        self.running.store(false, .release);
        self.send_th.join();
    }
}

const GetReqBufError = error{InvalidIndex};

fn getReqBuf(self: *RequestSender, idx: u8) GetReqBufError!*RequestChunkBuffer {
    if (idx < self.enc_file_reqs.cryptors.len) {
        return &self.enc_file_reqs.cryptors[idx].request_cbuf;
    } else if (idx == Cryptor.CryptorCluster.num_cryptors) {
        return &self.prio_request;
    } else return GetReqBufError.InvalidIndex;
}

fn waitUntilAvailable(self: *RequestSender) u8 {
    self.enc_file_reqs.idx_lock.lock();
    defer self.enc_file_reqs.idx_lock.unlock();

    while (self.enc_file_reqs.avail_idx == pipe_adapter.RequestPipeAdapter.invalid_index)
        self.enc_file_reqs.avail_cond.wait(&self.enc_file_reqs.idx_lock);

    const idx = self.enc_file_reqs.avail_idx;
    self.enc_file_reqs.avail_idx = pipe_adapter.RequestPipeAdapter.invalid_index;
    return idx;
}

pub fn signalPriorityRequest(self: *@This()) void {
    self.enc_file_reqs.idx_lock.lock();
    defer self.enc_file_reqs.idx_lock.unlock();

    self.enc_file_reqs.avail_idx = Cryptor.CryptorCluster.num_cryptors;
    self.enc_file_reqs.avail_cond.signal();
}

fn readBuf(self: *RequestSender) []u8 {
    {
        self.enc_file_reqs.idx_lock.lock();
        defer self.enc_file_reqs.idx_lock.unlock();

        self.enc_file_reqs.avail_idx = pipe_adapter.RequestPipeAdapter.invalid_index;
    }

    for (0..self.enc_file_reqs.cryptors.len + 2) |i| {
        const idx = if (i == self.enc_file_reqs.cryptors.len + 1) self.waitUntilAvailable() else i;
        const req_buf_res = self.getReqBuf(idx) catch unreachable;

        req_buf_res.chunk_buf.w_lock.lock();
        defer req_buf_res.chunk_buf.w_lock.unlock();

        if (req_buf_res.chunk_buf.empty == .full)
            return req_buf_res.chunk_buf.getBuf()[0..req_buf_res.chunk_buf.data_len];
    }
}

fn finishReadBuf(self: *RequestSender, used_buf: []u8) void {
    for (self.enc_file_reqs.cryptors) |*cryptor| {
        if (used_buf.ptr == &cryptor.request_cbuf.chunk_buf.back_buf) {
            cryptor.request_cbuf.chunk_buf.signalState(.empty);
            return;
        }
    }

    if (used_buf.ptr == self.prio_request.chunk_buf.back_buf.ptr)
        self.prio_request.chunk_buf.signalState(.empty);
}

fn sendLoop(self: *RequestSender) void {
    while (self.running.load(.acquire)) {
        const req_buf = self.readBuf();
        defer self.finishReadBuf(req_buf);

        self.tcp_cli.sendAll(req_buf) catch {
            //  TODO: handle error
            std.log.err("sending file failed", .{});
        };
    }
}
