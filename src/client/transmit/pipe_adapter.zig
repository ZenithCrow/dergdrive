const std = @import("std");
const Thread = std.Thread;

const Cryptor = @import("Cryptor.zig");
const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");
const RequestChunkBuffer = @import("RequestChunkBuffer.zig");

pub fn PipeAdapter(comptime raw_side: bool) type {
    return struct {
        pub const Operation = enum(u1) {
            read = 1,
            write = 0,
        };

        pub const invalid_index: u8 = std.math.maxInt(u8);

        const ChunkBufT = if (raw_side) RawFileChunkBuffer else RequestChunkBuffer;

        cryptors: []Cryptor,
        avail_idx: u8 = 0,
        idx_lock: std.Io.Mutex = .init,
        avail_cond: std.Io.Condition = .init,

        pub fn waitUntilAvailable(self: *@This(), io: std.Io) std.Io.Cancelable!u8 {
            try self.idx_lock.lock(io);
            defer self.idx_lock.unlock(io);

            while (self.avail_idx == invalid_index)
                try self.avail_cond.wait(io, &self.idx_lock);

            const idx = self.avail_idx;
            self.avail_idx = invalid_index;
            return idx;
        }

        pub fn signalIndexAvailable(self: *@This(), idx: u8, io: std.Io) void {
            const old_cancel_protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(old_cancel_protection);

            self.idx_lock.lock(io) catch unreachable;
            defer self.idx_lock.unlock(io);

            self.avail_idx = idx;
            self.avail_cond.signal(io);
        }

        pub fn signalCryptorAvailable(self: *@This(), cryptor: *Cryptor, io: std.Io) void {
            const old_cancel_protection = io.swapCancelProtection(.blocked);
            defer _ = io.swapCancelProtection(old_cancel_protection);

            self.idx_lock.lock(io) catch unreachable;
            defer self.idx_lock.unlock(io);

            for (self.cryptors, 0..) |*c, i| {
                if (c == cryptor) {
                    self.avail_idx = @as(u8, @truncate(i));
                    self.avail_cond.signal(io);
                    return;
                }
            }
        }

        pub fn claimChunkBuf(self: *@This(), op: Operation, io: std.Io) std.Io.Cancelable!*ChunkBufT {
            {
                try self.idx_lock.lock(io);
                defer self.idx_lock.unlock(io);

                self.avail_idx = invalid_index;
            }

            for (0..self.cryptors.len + 1) |i| {
                const idx = if (i == self.cryptors.len) try self.waitUntilAvailable(io) else i;
                const cryptor = &self.cryptors[idx];
                const cbuf: *ChunkBufT = if (raw_side) &cryptor.raw_file_cbuf else &cryptor.request_cbuf;

                try cbuf.chunk_buf.w_lock.lock(io);
                defer cbuf.chunk_buf.w_lock.unlock(io);

                if ((@intFromEnum(op) ^ @intFromEnum(cbuf.chunk_buf.empty)) == 0)
                    return cbuf;
            }

            unreachable;
        }

        pub fn unclaimChunkBuf(self: *@This(), used_buf: *ChunkBufT, perf_op: Operation, io: std.Io) void {
            for (self.cryptors) |*cryptor| {
                const cbuf: *ChunkBufT = if (raw_side) &cryptor.raw_file_cbuf else &cryptor.request_cbuf;

                if (cbuf == used_buf)
                    cbuf.chunk_buf.signalState(if (perf_op == .write) .full else .empty, io);
            }
        }
    };
}

pub const RawFilePipeAdapter = PipeAdapter(true);
pub const RequestPipeAdapter = PipeAdapter(false);
