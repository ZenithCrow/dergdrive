const std = @import("std");

const dergdrive = @import("dergdrive");

const BreakChunk = @import("BreakChunk.zig");
const Chunk = @import("Chunk.zig");
const header = @import("header.zig");
const KeyXchgChunk = @import("KeyXchgChunk.zig");
const SyncMessage = @import("SyncMessage.zig");
const VersionChunk = @import("VersionChunk.zig");

const MsgChunkSnake = @This();

pub const Error = error{SeeErrorDescription} || Chunk.CreateError;

msg: SyncMessage,
data_buf_pos: usize = 0,
err: ?Error = null,
err_desc: ?[]u8 = null,

pub fn fromBuf(buf: []u8) MsgChunkSnake {
    return .{ .msg = .{ .msg_buf = buf } };
}

fn advanceChunk(self: *MsgChunkSnake, comptime ChunkT: type) void {
    self.data_buf_pos += header.header_size + ChunkT.content_size;
}

fn remainingBuf(self: MsgChunkSnake) []u8 {
    return self.msg.dataBuf()[self.data_buf_pos..];
}

pub fn version(self: *MsgChunkSnake, semver: ?std.SemanticVersion) *MsgChunkSnake {
    if (self.err == null) {
        var ver_c = Chunk.createChunk(VersionChunk, self.remainingBuf()) catch |err| {
            self.err = err;
            return self;
        };

        ver_c.set(semver);
        ver_c.write();

        self.advanceChunk(VersionChunk);
    }

    return self;
}

pub fn keyxchg(
    self: *MsgChunkSnake,
    pub_key: [dergdrive.crypt.KeyxchAlgo.public_length]u8,
    pub_sign_key: ?[dergdrive.crypt.SignAlgo.PublicKey.encoded_length]u8,
    signature: ?[dergdrive.crypt.SignAlgo.Signature.encoded_length]u8,
) *MsgChunkSnake {
    if (self.err == null) {
        var kxchg_c = Chunk.createChunk(KeyXchgChunk, self.remainingBuf()) catch |err| {
            self.err = err;
            return self;
        };

        kxchg_c.pub_xchg_key = pub_key;
        if (pub_sign_key) |psk| kxchg_c.pub_sign_key = psk;
        if (signature) |sig| kxchg_c.signature = sig;
        kxchg_c.write();

        self.advanceChunk(KeyXchgChunk);
    }

    return self;
}

pub fn finalize(self: *MsgChunkSnake) Error!SyncMessage {
    _ = Chunk.createChunk(BreakChunk, self.remainingBuf()) catch {};

    self.msg.containMsgInSizeHeader();
    self.msg.updateHeader() catch unreachable;

    if (self.err) |e| return e;

    return self.msg;
}
