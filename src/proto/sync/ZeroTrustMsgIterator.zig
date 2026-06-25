const std = @import("std");

const dergdrive = @import("dergdrive");

const header = @import("header.zig");
const SyncMessage = @import("SyncMessage.zig");

const ZeroTrustMsgIterator = @This();

const log = std.log.scoped(.@"proto/sync/ZeroTrustMsgIterator");

seek: usize = 0,
end: usize = 0,
buf: []u8,

pub fn nextMsg(self: *ZeroTrustMsgIterator, reader: *std.Io.Reader) std.Io.Reader.Error!SyncMessage {
    std.debug.assert(self.seek <= self.end);
    if (self.buf.len - self.seek < header.header_size)
        self.rebase();

    var msg_len: usize = undefined;
    while (true) {
        if (std.mem.find(u8, self.buf[self.seek..self.end], SyncMessage.header_title)) |msg_start| {
            if (self.end - msg_start >= header.header_size) {
                msg_len = header.header_size + std.mem.readInt(header.DataLenT, self.buf[msg_start + header.header_title_size .. msg_start + header.header_title_size + header.data_len_size][0..header.data_len_size], .little);
                if (msg_len <= dergdrive.proto.common.op_buf_size) {
                    self.seek = msg_start;
                    break;
                }

                log.warn("Failed to parse message: too long.", .{});
            }
        }

        self.seek = 0;
        self.end = 0;
        try self.pull(reader);
        log.debug("pulled: '{s}' {any}", .{ self.buf[self.seek..self.end], self.buf[self.seek..self.end] });
    }

    if (self.seek + msg_len > self.buf.len)
        self.rebase();

    while (self.seek + msg_len > self.end)
        try self.pull(reader);

    const msg_start = self.seek;
    self.seek += msg_len;

    return .{ .msg_buf = self.buf[msg_start .. msg_start + msg_len] };
}

fn pull(self: *ZeroTrustMsgIterator, reader: *std.Io.Reader) std.Io.Reader.Error!void {
    var vec = [_][]u8{self.buf[self.end..]};
    self.end += try reader.readVec(&vec);
}

fn rebase(self: *ZeroTrustMsgIterator) void {
    @memmove(self.buf[0 .. self.end - self.seek], self.buf[self.seek..self.end]);
    self.end -= self.seek;
    self.seek = 0;
}
