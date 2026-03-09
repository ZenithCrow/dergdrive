const std = @import("std");
const Thread = std.Thread;

const crypt = @import("dergdrive").crypt;
pub const enc_add_info_len = crypt.nonce_auth_len;
const sync = @import("dergdrive").proto.sync;

const pipe_adapter = @import("pipe_adapter.zig");
const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");

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
    cryptors: [num_cryptors]Cryptor = undefined,
    th_pool: std.Thread.Pool = undefined,
    allocator: std.mem.Allocator,

    pub fn init(self: *@This(), id_supply: *sync.RequestChunk.IdSupplier) void {
        for (&self.cryptors) |*cryptor| {
            cryptor.* = .{
                .raw_file_cbuf = .{},
                .request_cbuf = .init(id_supply),
                .cluster = self,
            };

            cryptor.request_cbuf.initTransmitFileMsg();
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
                .encrypt => try self.th_pool.spawn(pipeEncrypted, cryptor),
                .decrypt => try self.th_pool.spawn(pipeDecrypted, cryptor),
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

        const in_buf = self.raw_file_cbuf.chunk_buf.getBuf()[0..self.raw_file_cbuf.chunk_buf.data_len];
        const out_buf_all = self.request_cbuf.trns_msg.newMsg(in_buf + crypt.nonce_auth_len, self.raw_file_cbuf.request.request_type) catch unreachable;
        var auth_tag: [crypt.AesAlgo.tag_length]u8 = undefined;
        var nonce: [crypt.AesAlgo.nonce_length]u8 = undefined;
        std.crypto.random.bytes(&nonce);

        std.mem.copyForwards(u8, out_buf_all[crypt.AesAlgo.tag_length..crypt.nonce_auth_len], &nonce);
        const out_buf = out_buf_all[crypt.nonce_auth_len..];

        crypt.AesAlgo.encrypt(out_buf, &auth_tag, in_buf, &nonce, &nonce, &self.cluster.key);
        std.mem.copyForwards(u8, out_buf_all[0..crypt.AesAlgo.tag_length], &auth_tag);

        self.cluster.raw_file_pa.?.signalCryptorAvailable(self);
        self.cluster.request_pa.?.signalCryptorAvailable(self);
    }
}

pub fn pipeDecrypted(self: *Cryptor) !void {
    while (self.running.load(.acquire)) {
        // TODO rework this entirely once networking is in place
        self.request_cbuf.chunk_buf.waitUntilState(.full);
        self.raw_file_cbuf.chunk_buf.waitUntilState(.empty);

        // TODO forward request
        var in_buf = &[_]u8{}; // TODO get network enc content buffer here
        const auth_tag = in_buf[0..crypt.AesAlgo.tag_length];
        const nonce = in_buf[crypt.AesAlgo.tag_length..crypt.nonce_auth_len];
        in_buf = in_buf[crypt.nonce_auth_len..];

        const out_buf = self.raw_file_cbuf.back_buf[0..in_buf.len];

        // TODO report integrity violation
        crypt.AesAlgo.decrypt(out_buf, in_buf, auth_tag, nonce, nonce, &self.cluster.key) catch continue;

        {
            self.raw_file_cbuf.w_lock.lock();
            defer self.raw_file_cbuf.w_lock.unlock();

            self.raw_file_cbuf.data_len = out_buf.len;
        }

        self.cluster.request_pa.signalCryptorAvailable(self);
        self.cluster.raw_file_pa.signalCryptorAvailable(self);
    }
}
