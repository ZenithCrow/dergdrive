const std = @import("std");
const net = std.Io.net;

const dergdrive = @import("dergdrive");
const common = dergdrive.proto.common;
const ZeroTrustMsgIterator = dergdrive.proto.sync.ZeroTrustMsgIterator;
const sync = dergdrive.proto.sync;

const ConnectionWorker = @This();

const log = std.log.scoped(.@"server/rxtx/ConnectionWorker");

stream: net.Stream,
write_buf: []u8,
data_len: usize = 0,
read_buf: []u8,
write_lock: std.Io.Mutex = .init,
write_cond: std.Io.Condition = .init,
read_task: ?std.Io.Future(net.Stream.Reader.Error!void) = null,
write_task: ?std.Io.Future(net.Stream.Writer.Error!void) = null,

pub fn init(stream: net.Stream, gpa: std.mem.Allocator) std.mem.Allocator.Error!ConnectionWorker {
    const write_buf = try gpa.alloc(u8, common.op_buf_size);
    errdefer gpa.free(write_buf);
    const read_buf = try gpa.alloc(u8, common.op_buf_size);
    errdefer gpa.free(read_buf);

    return .{
        .stream = stream,
        .write_buf = write_buf,
        .read_buf = read_buf,
    };
}

pub fn deinit(self: *ConnectionWorker, gpa: std.mem.Allocator, io: std.Io) void {
    self.stop(io);

    gpa.free(self.write_buf);
    gpa.free(self.read_buf);
}

pub fn start(self: *ConnectionWorker, io: std.Io) std.Io.ConcurrentError!void {
    std.debug.assert(self.read_task == null);

    self.read_task = try io.concurrent(readLoop, .{ self, io });
    self.write_task = try io.concurrent(writeLoop, .{ self, io });
}

/// idempotent
pub fn stop(self: *ConnectionWorker, io: std.Io) void {
    if (self.read_task) |*t| {
        t.cancel(io) catch |err| {
            log.warn("Collecting net read task with error: {t}.", .{err});
        };
        self.read_task = null;
    }

    if (self.write_task) |*t| {
        t.cancel(io) catch |err| {
            log.warn("Collecting net write task with error: {t}.", .{err});
        };
        self.write_task = null;
    }
}

fn readLoop(self: *ConnectionWorker, io: std.Io) net.Stream.Reader.Error!void {
    var reader = self.stream.reader(io, &.{});
    var msg_iter: ZeroTrustMsgIterator = .{ .buf = self.read_buf };

    while (true) {
        const msg = msg_iter.nextMsg(&reader.interface) catch |err| switch (err) {
            std.Io.Reader.Error.ReadFailed => switch (reader.err.?) {
                net.Stream.Reader.Error.Canceled => |e| return e,
                else => |e| {
                    log.err("Couldn't read from net reader due to error: {t}.", .{e});
                    return e;
                },
            },
            std.Io.Reader.Error.EndOfStream => {
                log.info("Client {f} disconnected.", .{self.stream.socket.address});
                return;
            },
        };
        var chunk_iter = msg.iter();

        const chunk = chunk_iter.next() catch |err| {
            log.warn("Failed to parse chunk due to error: {t}.", .{err});
            continue;
        };

        if (chunk) |c| {
            log.debug("parsing chunk: {t}", .{c.chunk_type});
            switch (c.chunk_type) {
                .version => {
                    var ver_snake: sync.MsgChunkSnake = .fromBuf(self.write_buf);
                    const ver_msg = ver_snake.version(null).finalize() catch unreachable;
                    const ver_msg_size = ver_msg.getMsgSize() catch unreachable;
                    self.writer.interface.writeAll(ver_msg.msg_buf[0..ver_msg_size]) catch {
                        log.err("write failed", .{});
                    };
                },
                .key_xchg => {
                    const kxchg_keypair: dergdrive.crypt.KeyxchAlgo.KeyPair = .generate(io);
                    const sign_keypair: dergdrive.crypt.SignAlgo.KeyPair = .generate(io);
                    var noise: [dergdrive.crypt.SignAlgo.noise_length]u8 = undefined;
                    std.Io.random(io, &noise);
                    const signature = sign_keypair.sign(&kxchg_keypair.public_key, noise) catch unreachable;
                    log.debug("kxchg_key: {b64}", .{kxchg_keypair.public_key});
                    log.debug("sign_key: {b64}", .{sign_keypair.public_key.toBytes()});
                    log.debug("signature: {b64}", .{signature.toBytes()});

                    var kxchg_snake: sync.MsgChunkSnake = .fromBuf(self.write_buf);
                    const kxchg_msg = kxchg_snake.keyxchg(
                        kxchg_keypair.public_key,
                        sign_keypair.public_key.toBytes(),
                        signature.toBytes(),
                    ).finalize() catch unreachable;
                    const kxchg_msg_len = kxchg_msg.getMsgSize() catch unreachable;
                    self.writer.interface.writeAll(kxchg_msg.msg_buf[0..kxchg_msg_len]) catch {
                        log.err("write failed", .{});
                    };
                },
                else => {},
            }
        } else {
            log.warn("Failed to parse chunk: message is empty", .{});
            continue;
        }
    }
}

fn writeLoop(self: *ConnectionWorker, io: std.Io) net.Stream.Writer.Error!void {
    var writer = self.stream.writer(io, &.{});

    while (true) {
        try self.write_lock.lock(io);
        defer self.write_lock.unlock(io);

        while (self.data_len == 0)
            try self.write_cond.wait(io, &self.write_lock);

        writer.interface.writeAll(self.write_buf[0..self.data_len]) catch switch (writer.err.?) {
            net.Stream.Writer.Error.Canceled => |e| return e,
            else => |e| {
                log.err("Couldn't write to net reader due to error: {t}.", .{e});
                return e;
            },
        };
    }
}
