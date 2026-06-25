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
read_buf: []u8,
writer: net.Stream.Writer,
write_lock: std.Io.Mutex,
read_task: ?std.Io.Future(net.Stream.Reader.Error!void) = null,

pub fn init(stream: net.Stream, gpa: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!ConnectionWorker {
    const write_buf = try gpa.alloc(u8, common.op_buf_size);
    errdefer gpa.free(write_buf);
    const read_buf = try gpa.alloc(u8, common.op_buf_size);
    errdefer gpa.free(read_buf);

    return .{
        .stream = stream,
        .write_buf = write_buf,
        .read_buf = read_buf,
        .writer = stream.writer(io, &.{}),
        .write_lock = .init,
    };
}

pub fn deinit(self: ConnectionWorker, gpa: std.mem.Allocator) void {
    gpa.free(self.write_buf);
    gpa.free(self.read_buf);
}

pub fn start(self: *ConnectionWorker, io: std.Io) std.Io.ConcurrentError!void {
    std.debug.assert(self.read_task == null);

    self.read_task = try io.concurrent(readLoop, .{ self, io });
}

pub fn stop(self: *ConnectionWorker, io: std.Io) void {
    if (self.read_task) |*t| {
        t.cancel(io) catch {};
        self.read_task = null;
    }
}

pub fn readLoop(self: *ConnectionWorker, io: std.Io) net.Stream.Reader.Error!void {
    var reader = self.stream.reader(io, &.{});
    var msg_iter: ZeroTrustMsgIterator = .{ .buf = self.read_buf };

    while (true) {
        const msg = msg_iter.nextMsg(&reader.interface) catch |err| switch (err) {
            std.Io.Reader.Error.ReadFailed => {
                log.err("Couldn't read from reader due to error: {t}.", .{reader.err.?});
                return reader.err.?;
            },
            std.Io.Reader.Error.EndOfStream => return,
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
                    const signature = sign_keypair.sign(&sign_keypair.public_key.toBytes(), null) catch unreachable;

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
