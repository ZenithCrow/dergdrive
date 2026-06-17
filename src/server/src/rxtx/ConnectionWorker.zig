const std = @import("std");
const net = std.Io.net;

const dergdrive = @import("dergdrive");
const common = dergdrive.proto.common;
const ZeroTrustMsgIterator = dergdrive.proto.sync.ZeroTrustMsgIterator;

const ConnectionWorker = @This();

const log = std.log.scoped(.@"server/rxtx/ConnectionWorker");

// this is not a webserver, I expect little concurrent traffic, thus I'll be using a separate thread for each TCP connection

stream: net.Stream,
write_buf: []u8,
read_buf: []u8,
writer: net.Stream.Writer,
write_lock: std.Io.Mutex,

pub fn init(stream: net.Stream, gpa: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!ConnectionWorker {
    const alloc_buf = try gpa.alloc(u8, 2 * common.op_buf_size);
    const write_buf = alloc_buf[0..common.op_buf_size];

    return .{
        .stream = stream,
        .write_buf = write_buf,
        .read_buf = alloc_buf[common.op_buf_size..],
        .writer = stream.writer(io, write_buf),
        .write_lock = .init,
    };
}

pub fn work(self: *ConnectionWorker, io: std.Io) net.Stream.Reader.Error!void {
    var reader = self.stream.reader(io, &.{});
    var msg_iter: ZeroTrustMsgIterator = .{ .buf = self.read_buf };

    while (true) {
        const msg = msg_iter.nextMsg(&reader.interface) catch return reader.err.?;
        var chunk_iter = msg.iter();

        const chunk = chunk_iter.next() catch |err| {
            log.warn("Failed to parse chunk due to error: {t}.", .{err});
            continue;
        };

        if (chunk) |c| {
            switch (c.chunk_type) {
                .request => {},
                else => {},
            }
        } else {
            log.warn("Failed to parse chunk: message is empty", .{});
            continue;
        }
    }
}
