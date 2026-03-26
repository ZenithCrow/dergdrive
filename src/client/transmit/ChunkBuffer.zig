const std = @import("std");
const Thread = std.Thread;

const ChunkBuffer = @This();

pub const EmptyState = enum(u1) {
    empty = 0,
    full = 1,
};

pub const chunk_size = 0x400000; // 4 MiB

back_buf: [chunk_size]u8 = undefined,
buf_len: usize,
data_len: usize = 0,
empty: EmptyState = .empty,
w_lock: Thread.Mutex = .{},
state_cond: Thread.Condition = .{},

pub inline fn getBuf(self: *ChunkBuffer) []u8 {
    return self.back_buf[0..self.buf_len];
}

pub inline fn getWrittenBuf(self: *ChunkBuffer) []const u8 {
    return self.back_buf[0..self.data_len];
}

pub fn waitUntilState(self: *ChunkBuffer, empty: EmptyState) void {
    self.w_lock.lock();
    defer self.w_lock.unlock();

    while (self.empty != empty)
        self.state_cond.wait(&self.w_lock);
}

pub fn signalState(self: *ChunkBuffer, empty: EmptyState) void {
    self.w_lock.lock();
    defer self.w_lock.unlock();

    self.empty = empty;
    if (empty == .full)
        self.data_len = 0;

    self.state_cond.signal();
}
