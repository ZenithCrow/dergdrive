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

pub const Cluster = struct {
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

    pub fn init(key: [crypt.key_length]u8, req_stor: *RequestStorage, num_cryptors: u8) Cluster {
        return .{
            .key = key,
            .request_storage = req_stor,
            .num_cryptors = num_cryptors,
        };
    }

    pub fn initCryptors(self: *Cluster, allocator: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.cryptors = self.cryptors_arr[0..self.num_cryptors];

        for (self.cryptors, 0..) |*cryptor, i| {
            cryptor.* = Cryptor.init(self, allocator) catch |err| {
                log.err("Failed to initialize the specified number of cryptors ({d}) due to error: {t}.", .{ self.num_cryptors, err });
                self.num_cryptors = @truncate(i);
                self.cryptors = self.cryptors[0..i];
                log.warn("The current number of cryptors is: {d}.", .{self.num_cryptors});
                break;
            };

            cryptor.request_cbuf.initTransmitFileMsg() catch unreachable;
        }

        log.debug("{d} cryptors runnning.", .{self.num_cryptors});
    }

    pub fn deinitCryptors(self: Cluster, allocator: std.mem.Allocator) void {
        for (self.cryptors) |c| {
            c.deinit(allocator);
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

        for (self.cryptors) |*cryptor| {
            try self.group.concurrent(io, comptime switch (dir) {
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
cluster: *Cluster,

pub fn init(crypt_cluster: *Cluster, allocator: std.mem.Allocator) std.mem.Allocator.Error!Cryptor {
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

pub fn deinit(self: Cryptor, allocator: std.mem.Allocator) void {
    self.raw_file_cbuf.deinit(allocator);
    self.request_cbuf.deinit(allocator);
}

pub fn pipeEncrypted(self: *Cryptor, io: std.Io) std.Io.Cancelable!void {
    while (true) {
        try self.raw_file_cbuf.chunk_buf.waitUntilState(.full, io);
        try self.request_cbuf.chunk_buf.waitUntilState(.empty, io);

        const cryptor_idx = for (self.cluster.cryptors, 0..) |*c, i| {
            if (c == self)
                break i;
        } else unreachable;

        log.debug("Cryptor {d} has picked up a job.", .{cryptor_idx});

        const old_cancel_protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(old_cancel_protection);

        const req = lock_blk: {
            self.cluster.request_storage.req_stor_lock.lockUncancelable(io);
            defer self.cluster.request_storage.req_stor_lock.unlock(io);

            break :lock_blk self.cluster.request_storage.reqs.get(self.raw_file_cbuf.req_id.?).?;
        };

        const in_buf = self.raw_file_cbuf.chunk_buf.getWrittenBufProtected(io) catch unreachable;
        defer self.raw_file_cbuf.chunk_buf.setBufEmptyProtected(io) catch unreachable;

        const out_final_size = sync.templates.TransmitChunkMsg.non_payload_size + crypt.nonce_auth_len + in_buf.len;

        const out_buf_all = self.request_cbuf.trns_msg.newMsg(
            @as(u32, @intCast(in_buf.len)) + crypt.nonce_auth_len,
            req.query,
            req.id,
        ) catch unreachable;

        self.request_cbuf.req_id = self.raw_file_cbuf.req_id;
        switch (req.query) {
            .chunk_update => |f_push| self.request_cbuf.trns_msg.dest_chunk.valuesFromQuery(f_push.dest),
            .chunk_new => {},
            else => unreachable,
        }
        self.request_cbuf.trns_msg.dest_chunk.write();

        var auth_tag: [crypt.AesAlgo.tag_length]u8 = undefined;
        var nonce: [crypt.AesAlgo.nonce_length]u8 = undefined;
        io.random(&nonce);

        std.mem.copyForwards(u8, out_buf_all[crypt.AesAlgo.tag_length..crypt.nonce_auth_len], &nonce);
        const out_buf = out_buf_all[crypt.nonce_auth_len..];

        crypt.AesAlgo.encrypt(out_buf, &auth_tag, in_buf, &nonce, nonce, self.cluster.key);
        std.mem.copyForwards(u8, out_buf_all[0..crypt.AesAlgo.tag_length], &auth_tag);

        self.raw_file_cbuf.req_id = null;

        {
            self.request_cbuf.chunk_buf.w_lock.lockUncancelable(io);
            defer self.request_cbuf.chunk_buf.w_lock.unlock(io);

            self.request_cbuf.chunk_buf.data_len = out_final_size;
            self.request_cbuf.chunk_buf.setState(.full);
        }

        log.debug("Cryptor {d} has finished its job", .{cryptor_idx});

        self.cluster.raw_file_pa.?.signalCryptorFinished(self, io);
        self.cluster.request_pa.?.signalCryptorFinished(self, io);
    }
}

pub fn pipeDecrypted(self: *Cryptor) !void {
    _ = self;
    while (true) {
        //  TODO: do this once networking is in place
    }
}
