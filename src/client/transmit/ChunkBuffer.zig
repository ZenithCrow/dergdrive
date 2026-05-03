const std = @import("std");

const ChunkBuffer = @This();

pub const FillState = enum(u1) {
    empty = 0,
    full = 1,
};

pub const chunk_size = 0x400000; // 4 MiB

buf: []u8,
data_len: usize = 0,
empty: FillState = .empty,
w_lock: std.Io.Mutex = .init,
state_cond: std.Io.Condition = .init,

pub inline fn getWrittenBuf(self: *ChunkBuffer) []const u8 {
    return self.buf[0..self.data_len];
}

pub fn waitUntilState(self: *ChunkBuffer, empty: FillState, io: std.Io) std.Io.Cancelable!void {
    try self.w_lock.lock(io);
    defer self.w_lock.unlock(io);

    while (self.empty != empty)
        try self.state_cond.wait(io, &self.w_lock);
}

pub fn signalState(self: *ChunkBuffer, empty: FillState, io: std.Io) void {
    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    self.w_lock.lock(io) catch unreachable;
    defer self.w_lock.unlock(io);

    self.empty = empty;
    if (empty == .full)
        self.data_len = 0;

    self.state_cond.signal(io);
}
