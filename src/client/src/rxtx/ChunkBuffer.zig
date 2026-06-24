const std = @import("std");

const ChunkBuffer = @This();

pub const FillState = enum(u1) {
    empty = 0,
    full = 1,
};

buf: []u8,
data_len: usize = 0,
fill_state: FillState = .empty,
w_lock: std.Io.Mutex = .init,
state_cond: std.Io.Condition = .init,

pub fn getWrittenBufProtected(self: *ChunkBuffer, io: std.Io) std.Io.Cancelable![]const u8 {
    try self.w_lock.lock(io);
    defer self.w_lock.unlock(io);

    return self.buf[0..self.data_len];
}

pub fn setBufEmptyProtected(self: *ChunkBuffer, io: std.Io) std.Io.Cancelable!void {
    try self.w_lock.lock(io);
    defer self.w_lock.unlock(io);

    self.setState(.empty);
}

pub fn waitUntilState(self: *ChunkBuffer, fill_state: FillState, io: std.Io) std.Io.Cancelable!void {
    try self.w_lock.lock(io);
    defer self.w_lock.unlock(io);

    while (self.fill_state != fill_state)
        try self.state_cond.wait(io, &self.w_lock);
}

pub fn setState(self: *ChunkBuffer, fill_state: FillState) void {
    self.fill_state = fill_state;
    if (fill_state == .empty)
        self.data_len = 0;
}

pub fn setStateAndSignal(self: *ChunkBuffer, fill_state: FillState, io: std.Io) std.Io.Cancelable!void {
    try self.w_lock.lock(io);
    defer self.w_lock.unlock(io);

    self.setState(fill_state);
    self.state_cond.signal(io);
}
