const std = @import("std");

const BreakChunk = @import("BreakChunk.zig");
const DestChunk = @import("DestChunk.zig");
const EncryptedPayloadChunk = @import("EncryptedPayloadChunk.zig");
const header = @import("header.zig");
const KeyXchgChunk = @import("KeyXchgChunk.zig");
const PayloadChunk = @import("PayloadChunk.zig");
const RequestChunk = @import("RequestChunk.zig");
const SyncMessage = @import("SyncMessage.zig");

pub const Iterator = struct {
    buffer: []u8,
    index: usize = 0,

    pub fn next(self: *Iterator) ReadError!?Chunk {
        if (self.index >= self.buffer.len) return null;

        const chunk = readChunk(self.buffer[self.index..]) catch |err| return switch (err) {
            ReadError.IsBreakChunk => null,
            else => err,
        };
        self.index += chunk.getWrittenSize();

        return chunk;
    }
};

pub const ChunkType = enum {
    sync_message,
    request,
    destination,
    payload,
    @"break",
    encrypted_payload,
    key_xchg,

    pub const Error = error{
        UnknownChunkType,
    };

    const PackedStrT = @Int(.unsigned, 8 * header.header_title_size);
    fn packedString(title: [header.header_title_size]u8) PackedStrT {
        return std.mem.readInt(PackedStrT, &title, .little);
    }

    pub fn fromHeaderTitle(title: [header.header_title_size]u8) Error!ChunkType {
        return switch (packedString(title)) {
            packedString(SyncMessage.header_title.*) => .sync_message,
            packedString(RequestChunk.header_title.*) => .request,
            packedString(DestChunk.header_title.*) => .destination,
            packedString(PayloadChunk.header_title.*) => .payload,
            packedString(BreakChunk.header_title.*) => .@"break",
            packedString(EncryptedPayloadChunk.header_title.*) => .encrypted_payload,
            packedString(KeyXchgChunk.header_title.*) => .key_xchg,
            else => Error.UnknownChunkType,
        };
    }
};

const Chunk = @This();

pub const ReadError = error{
    InvalidHeader,
    DataLenMismatch,
    IsBreakChunk,
} || ChunkType.Error;

pub const CreateError = error{
    InsufficientBufferSpace,
};

pub const CastError = error{
    InsufficientDataLen,
};

chunk_type: ChunkType,
header_buf: []u8,
data: []u8,

/// the total size of the chunk including header and data
pub inline fn getWrittenSize(self: Chunk) header.DataLenT {
    return @as(header.DataLenT, @intCast(header.header_size + self.data.len));
}

pub inline fn updateSizeHeader(self: Chunk) void {
    std.mem.writeInt(header.DataLenT, self.header_buf[header.header_title_size..header.header_size], @truncate(self.data.len), .little);
}

pub fn readChunk(buffer: []u8) ReadError!Chunk {
    if (buffer.len < header.header_size)
        return ReadError.InvalidHeader;

    const size = std.mem.readInt(header.DataLenT, buffer[header.header_title_size .. header.header_title_size + header.data_len_size], .little);
    if (buffer.len < header.header_size + size)
        return ReadError.DataLenMismatch;

    return .{
        .header_buf = buffer[0..header.header_size],
        .data = buffer[header.header_size .. header.header_size + size],
        .chunk_type = switch (try ChunkType.fromHeaderTitle(buffer[0..header.header_title_size].*)) {
            .@"break" => return ReadError.IsBreakChunk,
            else => |chunk| chunk,
        },
    };
}

fn validateChunkType(comptime ChunkT: type) void {
    comptime switch (@typeInfo(ChunkT)) {
        .@"struct" => |struc| {
            for (struc.decls) |decl| {
                if (std.mem.eql(u8, decl.name, "content_size"))
                    break;
            } else @compileError("struct " ++ @typeName(ChunkT) ++ " is missing content_size declaration");
            for (struc.decls) |decl| {
                if (std.mem.eql(u8, decl.name, "header_title"))
                    break;
            } else @compileError("struct " ++ @typeName(ChunkT) ++ " is missing header_title declaration");
        },
        else => @compileError("ChunkT must be a struct type"),
    };

    if (!std.meta.hasFn(ChunkT, "fromChunk"))
        @compileError("missing fromChunk function on type " ++ @typeName(ChunkT));
}

pub fn createChunk(comptime ChunkT: type, buf: []u8) CreateError!ChunkT {
    comptime validateChunkType(ChunkT);

    const chunk_buf_size = header.header_size + ChunkT.content_size;
    if (buf.len < chunk_buf_size)
        return CreateError.InsufficientBufferSpace;

    const chunk_buf = buf[0..chunk_buf_size];
    var chunk: Chunk = .{
        .header_buf = chunk_buf[0..header.header_size],
        .data = chunk_buf[header.header_size..],
        .chunk_type = ChunkType.fromHeaderTitle(ChunkT.header_title.*) catch unreachable,
    };

    std.mem.copyForwards(u8, chunk.header_buf[0..header.header_title_size], ChunkT.header_title);
    chunk.updateSizeHeader();

    return chunk.as(ChunkT) catch unreachable;
}

pub fn as(chunk: Chunk, comptime ChunkT: type) CastError!ChunkT {
    comptime validateChunkType(ChunkT);

    if (chunk.data.len < ChunkT.content_size)
        return CastError.InsufficientDataLen;

    return ChunkT.fromChunk(chunk);
}
