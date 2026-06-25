const std = @import("std");

const dergdrive = @import("dergdrive");
const common = dergdrive.proto.common;
const sync = dergdrive.proto.sync;
const ZeroTrustMsgIterator = sync.ZeroTrustMsgIterator;

const RequestStorage = @import("RequestStorage.zig");

const RequestReceiver = @This();

const log = std.log.scoped(.@"client/rxtx/RequestReceiver");

reader: *std.Io.Reader,
read_buf: []u8,
req_stor: *RequestStorage,
receive_task: ?std.Io.Future(std.Io.Cancelable!void) = null,
has_error: bool = false,
error_lock: std.Io.Mutex = .init,
error_cond: std.Io.Condition = .init,

pub fn init(reader: *std.Io.Reader, req_stor: *RequestStorage, gpa: std.mem.Allocator) std.mem.Allocator.Error!RequestReceiver {
    return .{
        .reader = reader,
        .req_stor = req_stor,
        .read_buf = try gpa.alloc(u8, common.op_buf_size),
    };
}

pub fn deinit(self: RequestReceiver, gpa: std.mem.Allocator) void {
    gpa.free(self.read_buf);
}

pub fn start(self: *RequestReceiver, io: std.Io) std.Io.ConcurrentError!void {
    std.debug.assert(self.receive_task == null);

    self.receive_task = try io.concurrent(receiveLoop, .{ self, io });
}

pub fn stop(self: *RequestReceiver, io: std.Io) void {
    if (self.receive_task) |*t| t.cancel(io) catch {};
}

fn receiveLoop(self: *RequestReceiver, io: std.Io) std.Io.Cancelable!void {
    var msg_iter: ZeroTrustMsgIterator = .{ .buf = self.read_buf };

    while (true) {
        const msg = msg_iter.nextMsg(self.reader) catch |err| {
            log.warn("Couldn't read from reader due to error: {t}.", .{err});

            try self.error_lock.lock(io);
            defer self.error_lock.unlock(io);

            self.has_error = true;
            self.req_stor.broadcastSubsystemFail(io);

            // wait until acknowledged by the main thread which determines the error recoverability
            while (self.has_error == true)
                try self.error_cond.wait(io, &self.error_lock);

            continue;
        };

        var chunk_iter = msg.iter();

        const chunk = chunk_iter.next() catch |err| {
            log.warn("Failed to parse chunk due to error: {t}.", .{err});
            continue;
        };

        if (chunk) |c| {
            switch (c.chunk_type) {
                .request => {},
                .version => {
                    const version_chunk = c.as(sync.VersionChunk) catch {
                        log.warn(sync.Chunk.parse_err_msg, .{"version chunk"});
                        continue;
                    };

                    self.req_stor.broadcastReceived(.{
                        .by_resp_type = .{
                            .version = version_chunk,
                        },
                    }, io);
                },
                .key_xchg => {
                    const keyxchg_chunk = c.as(sync.KeyXchgChunk) catch {
                        log.warn(sync.Chunk.parse_err_msg, .{"key exchange chunk"});
                        continue;
                    };

                    self.req_stor.broadcastReceived(.{
                        .by_resp_type = .{
                            .key_xchg = keyxchg_chunk,
                        },
                    }, io);
                },
                else => {},
            }
        } else {
            log.warn("Failed to parse chunk: message is empty", .{});
            continue;
        }
    }
}
