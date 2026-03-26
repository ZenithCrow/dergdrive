const std = @import("std");

const DestChunk = @import("DestChunk.zig");
const header = @import("header.zig");
const PayloadChunk = @import("PayloadChunk.zig");
const RequestChunk = @import("RequestChunk.zig");
const SyncMessage = @import("SyncMessage.zig");

pub const Iterator = struct {
    buffer: []u8,
    index: usize = 0,

    pub fn next(self: *Iterator) ReadError!?Chunk {
        if (self.index >= self.buffer.len) return null;

        const chunk = try readChunk(self.buffer[self.index..]);
        self.index += chunk.getWrittenSize();

        return chunk;
    }
};

pub const ChunkType = enum {
    sync_message,
    request,
    destination,
    payload,

    const PackedStrT = @Type(.{ .int = .{ .bits = 8 * header.header_title_size, .signedness = .unsigned } });
    fn packedString(title: [header.header_title_size]u8) PackedStrT {
        return std.mem.readInt(PackedStrT, &title, .little);
    }

    pub fn fromHeaderTitle(title: [header.header_title_size]u8) ?ChunkType {
        return switch (packedString(title)) {
            packedString(SyncMessage.header_title.*) => .sync_message,
            packedString(RequestChunk.header_title.*) => .request,
            packedString(DestChunk.header_title.*) => .destination,
            packedString(PayloadChunk.header_title.*) => .payload,
            else => null,
        };
    }
};

const Chunk = @This();

pub const ReadError = error{
    InvalidHeader,
    UnknownChunkType,
    DataLenMismatch,
};

pub const CreateError = error{
    InsufficientBufferSpace,
};

chunk_type: ChunkType,
header_buf: []u8,
data: []u8,

/// the total size of the chunk including header and data
pub inline fn getWrittenSize(self: Chunk) header.DataLenT {
    return @as(header.DataLenT, @intCast(header.header_size + self.data.len));
}

pub inline fn updateSizeHeader(self: Chunk) void {
    std.mem.writeInt(header.DataLenT, self.header_buf[header.header_title_size..header.header_size], self.data.len, .little);
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
        .chunk_type = ChunkType.fromHeaderTitle(buffer[0..header.header_title_size].*) orelse return ReadError.UnknownChunkType,
    };
}

pub fn createChunk(comptime ChunkT: type, buf: []u8) CreateError!ChunkT {
    //  TODO: validation of ChunkT

    // switch (@typeInfo(ChunkT)) {
    //     .@"struct" => |struc| {
    //         if (!(for (struc.decls) |decl| {
    //             if (std.mem.eql(u8, decl.name, "content_size"))
    //                 break true;
    //         } else false)) @compileError("struct " ++ @typeName(ChunkT) ++ " is missing content_size declaration");
    //     },
    //     else => @compileError("ChunkT must be a struct type"),
    // }

    const chunk_buf_size = header.header_size + ChunkT.content_size;
    if (buf.len < chunk_buf_size)
        return CreateError.InsufficientBufferSpace;

    const chunk_buf = buf[0..chunk_buf_size];
    var chunk: Chunk = .{
        .header_buf = chunk_buf[0..header.header_size],
        .data = chunk_buf[header.header_size..],
        .chunk_type = ChunkType.fromHeaderTitle(ChunkT.header_title.*) orelse unreachable,
    };

    std.mem.copyForwards(u8, chunk.header_buf[0..header.header_title_size], ChunkT.header_title);
    chunk.updateSizeHeader();

    return chunk.as(ChunkT);
}

pub fn as(chunk: Chunk, comptime ChunkT: type) ChunkT {
    if (std.meta.hasFn(ChunkT, "fromChunk")) {
        return ChunkT.fromChunk(chunk);
    } else @compileError("missing fromChunk function on type " ++ @typeName(ChunkT));
}
