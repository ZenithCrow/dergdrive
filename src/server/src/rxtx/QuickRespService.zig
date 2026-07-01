const std = @import("std");

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const RootConf = dergdrive.conf.Conf;
const crypt = dergdrive.crypt;
const SecAuth = dergdrive.SecAuth;
const server = @import("server");
const Conf = server.Conf;

const QuickResponseService = @This();

const ver_msg_len = 2 * sync.header.header_size + sync.VersionChunk.content_size;
const handshake_len = 2 * sync.header.header_size + sync.KeyXchgChunk.content_size;

const ver_msg_prep: [ver_msg_len]u8 = blk: {
    var msg_buf: [ver_msg_len]u8 = undefined;
    var ver_snake: sync.MsgChunkSnake = .fromBuf(&msg_buf);
    _ = ver_snake.version(null).finalize() catch unreachable;
    break :blk msg_buf;
};

pub fn getHandshake(sec_auth: SecAuth, buf: *[handshake_len]u8, io: std.Io) SecAuth.GetPubXchgKeySig!void {
    std.mem.copyForwards(u8, buf[0..ver_msg_len], &ver_msg_prep);

    const sig = try sec_auth.getPubXchgKeySig(io);
    var kxhg_snake: sync.MsgChunkSnake = .fromBuf(buf[ver_msg_len..]);
    _ = kxhg_snake.keyxchg(sec_auth.dh_key_pair.public_key, sec_auth.sign_key_pair.?.public_key.toBytes(), sig).finalize() catch unreachable;
}
