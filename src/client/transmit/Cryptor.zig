const std = @import("std");
const Thread = std.Thread;

const crypt = @import("dergdrive").crypt;
pub const enc_add_info_len = crypt.nonce_auth_len;
const sync = @import("dergdrive").proto.sync;

const pipe_adapter = @import("pipe_adapter.zig");
const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const AtomicBool = std.atomic.Value(bool);

pub const CryptorCluster = struct {
    pub const CryptDir = enum {
        encrypt,
        decrypt,
    };

    pub const num_cryptors = 4;

    key: [crypt.key_length]u8,
    raw_file_pa: ?*pipe_adapter.RawFilePipeAdapter = null,
    request_pa: ?*pipe_adapter.RequestPipeAdapter = null,
    request_storage: *RequestStorage,
    cryptors: [num_cryptors]Cryptor = undefined,
    th_pool: std.Thread.Pool = undefined,
    allocator: std.mem.Allocator,

    pub fn init(self: *CryptorCluster) void {
        for (&self.cryptors) |*cryptor| {
            cryptor.* = .{
                .raw_file_cbuf = .{},
                .request_cbuf = .{},
                .cluster = self,
            };

            cryptor.request_cbuf.initTransmitFileMsg() catch unreachable;
        }
    }

    pub fn connectAdapters(self: *@This(), raw_pa: *pipe_adapter.RawFilePipeAdapter, req_pa: *pipe_adapter.RequestPipeAdapter) void {
        raw_pa.cryptors = &self.cryptors;
        req_pa.cryptors = &self.cryptors;
        self.raw_file_pa = raw_pa;
        self.request_pa = req_pa;
    }

    const ThreadPoolError = std.mem.Allocator.Error || Thread.SpawnError;
    pub const RunCryptorsError = error{AdaptersNotConnected} || ThreadPoolError;

    pub fn runCryptors(self: *@This(), comptime dir: CryptDir) RunCryptorsError!void {
        if (self.raw_file_pa == null or self.request_pa == null)
            return RunCryptorsError.AdaptersNotConnected;

        try self.th_pool.init(.{ .allocator = self.allocator, .n_jobs = num_cryptors });

        for (&self.cryptors) |*cryptor| {
            cryptor.running.store(true, .release);
            comptime switch (dir) {
                .encrypt => try self.th_pool.spawn(pipeEncrypted, .{cryptor}),
                .decrypt => try self.th_pool.spawn(pipeDecrypted, .{cryptor}),
            };
        }
    }

    pub fn stopCryptors(self: *@This()) void {
        for (&self.cryptors) |*cryptor| {
            cryptor.running.store(false, .release);
        }

        self.th_pool.deinit();
    }
};

const Cryptor = @This();

running: AtomicBool = .init(false),
raw_file_cbuf: RawFileChunkBuffer,
request_cbuf: RequestChunkBuffer,
cluster: *CryptorCluster,

pub fn pipeEncrypted(self: *Cryptor) !void {
    while (self.running.load(.acquire)) {
        self.raw_file_cbuf.chunk_buf.waitUntilState(.full);
        self.request_cbuf.chunk_buf.waitUntilState(.empty);

        const req = self.cluster.request_storage.pending_reqs.getPtr(self.raw_file_cbuf.req_id.?).?;

        const in_buf = self.raw_file_cbuf.chunk_buf.getWrittenBuf();
        const out_buf_all = self.request_cbuf.trns_msg.newMsg(
            @as(u32, @intCast(in_buf.len)) + crypt.nonce_auth_len,
            req.req_type,
            req.id,
        ) catch unreachable;

        self.request_cbuf.req_id = self.raw_file_cbuf.req_id;
        self.request_cbuf.trns_msg.dest_chunk.copyValues(switch (req.req_type) {
            .file_post => req.req.file_post.dest,
            .file_new => req.req.file_new.length,
            else => unreachable,
        });
        self.request_cbuf.trns_msg.dest_chunk.write();

        var auth_tag: [crypt.AesAlgo.tag_length]u8 = undefined;
        var nonce: [crypt.AesAlgo.nonce_length]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        std.mem.copyForwards(u8, out_buf_all[crypt.AesAlgo.tag_length..crypt.nonce_auth_len], &nonce);
        const out_buf = out_buf_all[crypt.nonce_auth_len..];

        crypt.AesAlgo.encrypt(out_buf, &auth_tag, in_buf, &nonce, nonce, self.cluster.key);
        std.mem.copyForwards(u8, out_buf_all[0..crypt.AesAlgo.tag_length], &auth_tag);

        self.raw_file_cbuf.req_id = null;

        self.cluster.raw_file_pa.?.signalCryptorAvailable(self);
        self.cluster.request_pa.?.signalCryptorAvailable(self);
    }
}

pub fn pipeDecrypted(self: *Cryptor) !void {
    while (self.running.load(.acquire)) {
        //  TODO: do this once networking is in place
    }
}
