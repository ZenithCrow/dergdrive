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
        idx_lock: Thread.Mutex = .{},
        avail_cond: Thread.Condition = .{},

        pub fn waitUntilAvailable(self: *@This()) u8 {
            self.idx_lock.lock();
            defer self.idx_lock.unlock();

            while (self.avail_idx == invalid_index)
                self.avail_cond.wait(&self.idx_lock);

            const idx = self.avail_idx;
            self.avail_idx = invalid_index;
            return idx;
        }

        pub fn signalIndexAvailable(self: *@This(), idx: u8) void {
            self.idx_lock.lock();
            defer self.idx_lock.unlock();

            self.avail_idx = idx;
            self.avail_cond.signal();
        }

        pub fn signalCryptorAvailable(self: *@This(), cryptor: *Cryptor) void {
            self.idx_lock.lock();
            defer self.idx_lock.unlock();

            for (self.cryptors, 0..) |*c, i| {
                if (c == cryptor) {
                    self.avail_idx = @as(u8, @truncate(i));
                    self.avail_cond.signal();
                    return;
                }
            }
        }

        pub fn claimChunkBuf(self: *@This(), op: Operation) *ChunkBufT {
            {
                self.idx_lock.lock();
                defer self.idx_lock.unlock();

                self.avail_idx = invalid_index;
            }

            for (0..self.cryptors.len + 1) |i| {
                const idx = if (i == self.cryptors.len) self.waitUntilAvailable() else i;
                const cryptor = &self.cryptors[idx];
                const cbuf: *ChunkBufT = if (raw_side) &cryptor.raw_file_cbuf else &cryptor.request_cbuf;

                cbuf.chunk_buf.w_lock.lock();
                defer cbuf.chunk_buf.w_lock.unlock();

                if ((@intFromEnum(op) ^ @intFromEnum(cbuf.chunk_buf.empty)) == 0)
                    return cbuf;
            }

            unreachable;
        }

        pub fn unclaimChunkBuf(self: *@This(), used_buf: *ChunkBufT, perf_op: Operation) void {
            for (self.cryptors) |*cryptor| {
                const cbuf: *ChunkBufT = if (raw_side) &cryptor.raw_file_cbuf else &cryptor.request_cbuf;

                if (cbuf == used_buf)
                    cbuf.chunk_buf.signalState(if (perf_op == .write) .full else .empty);
            }
        }
    };
}

pub const RawFilePipeAdapter = PipeAdapter(true);
pub const RequestPipeAdapter = PipeAdapter(false);
