const std = @import("std");

const sync = @import("dergdrive").proto.sync;

const ChunkBuffer = @import("ChunkBuffer.zig");
const Cryptor = @import("Cryptor.zig");
const RequestStorage = @import("RequestStorage.zig");

const RawFileChunkBuffer = @This();

chunk_buf: ChunkBuffer = .{ .buf_len = ChunkBuffer.chunk_size - (Cryptor.enc_add_info_len + sync.templates.TransmitFileMsg.non_payload_size) },
req_id: ?sync.RequestChunk.IdT = null,
