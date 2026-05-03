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

const log = std.log.scoped(.@"client/transmit/Cryptor");

pub const CryptorCluster = struct {
    pub const CryptDir = enum {
        encrypt,
        decrypt,
    };

    pub const max_cryptors = 16;

    key: [crypt.key_length]u8,
    raw_file_pa: ?*pipe_adapter.RawFilePipeAdapter = null,
    request_pa: ?*pipe_adapter.RequestPipeAdapter = null,
    request_storage: *RequestStorage,
    cryptors_arr: [max_cryptors]Cryptor = undefined,
    num_cryptors: u8,
    cryptors: []Cryptor = &.{},
    group: std.Io.Group = .init,

    pub fn init(key: [crypt.key_length]u8, req_stor: *RequestStorage, num_cryptors: u8) CryptorCluster {
        return .{
            .key = key,
            .request_storage = req_stor,
            .num_cryptors = num_cryptors,
        };
    }

    pub fn initCryptors(self: *CryptorCluster, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.cryptors = self.cryptors_arr[0..self.num_cryptors];

        for (self.cryptors, 0..) |*cryptor, i| {
            cryptor.* = Cryptor.init(self, allocator) catch |err| {
                log.err("Failed to initialize the specified number of cryptors ({d}) due to error: {t}.", .{ self.num_cryptors, err });
                self.num_cryptors = @truncate(i);
                self.cryptors = self.cryptors[0..i];
                log.warn("The current number of cryptors is: {d}.", .{self.num_cryptors});
                break;
            };
        }
    }

    pub fn initializedCryptorsConnectAdapters(self: *@This(), raw_pa: *pipe_adapter.RawFilePipeAdapter, req_pa: *pipe_adapter.RequestPipeAdapter) void {
        raw_pa.cryptors = self.cryptors;
        req_pa.cryptors = self.cryptors;
        self.raw_file_pa = raw_pa;
        self.request_pa = req_pa;
    }

    pub fn runCryptors(self: *@This(), comptime dir: CryptDir, io: std.Io) std.Io.ConcurrentError!void {
        std.debug.assert(self.raw_file_pa != null and self.request_pa != null);

        for (&self.cryptors) |*cryptor| {
            try io.concurrent(comptime switch (dir) {
                .encrypt => pipeEncrypted,
                .decrypt => pipeDecrypted,
            }, .{
                cryptor,
                io,
            });
        }
    }

    pub fn stopCryptors(self: *@This(), io: std.Io) void {
        self.group.cancel(io);
    }
};

const Cryptor = @This();

raw_file_cbuf: RawFileChunkBuffer,
request_cbuf: RequestChunkBuffer,
cluster: *CryptorCluster,

pub fn init(crypt_cluster: *CryptorCluster, allocator: std.mem.Allocator) std.mem.Allocator.Error!Cryptor {
    const raw_file_cbuf: RawFileChunkBuffer = try .init(allocator);
    errdefer raw_file_cbuf.deinit(allocator);

    const request_cbuf: RequestChunkBuffer = try .init(allocator);
    errdefer request_cbuf.deinit(allocator);

    return .{
        .raw_file_cbuf = raw_file_cbuf,
        .request_cbuf = request_cbuf,
        .cluster = crypt_cluster,
    };
}

pub fn pipeEncrypted(self: *Cryptor, io: std.Io) std.Io.Cancelable!void {
    while (true) {
        try self.raw_file_cbuf.chunk_buf.waitUntilState(.full, io);
        try self.request_cbuf.chunk_buf.waitUntilState(.empty, io);

        const old_cancel_protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old_cancel_protection);

        const req = lock_blk: {
            self.cluster.request_storage.reqs_lock.lock(io) catch unreachable;
            defer self.cluster.request_storage.reqs_lock.unlock(io);

            break :lock_blk self.cluster.request_storage.reqs.get(self.raw_file_cbuf.req_id.?).?;
        };

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
        io.random(&nonce);

        std.mem.copyForwards(u8, out_buf_all[crypt.AesAlgo.tag_length..crypt.nonce_auth_len], &nonce);
        const out_buf = out_buf_all[crypt.nonce_auth_len..];

        crypt.AesAlgo.encrypt(out_buf, &auth_tag, in_buf, &nonce, nonce, self.cluster.key);
        std.mem.copyForwards(u8, out_buf_all[0..crypt.AesAlgo.tag_length], &auth_tag);

        self.raw_file_cbuf.req_id = null;

        self.cluster.raw_file_pa.?.signalCryptorAvailable(self, io);
        self.cluster.request_pa.?.signalCryptorAvailable(self, io);
    }
}

pub fn pipeDecrypted(self: *Cryptor) !void {
    _ = self;
    while (true) {
        //  TODO: do this once networking is in place
    }
}
