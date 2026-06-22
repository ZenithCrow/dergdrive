const std = @import("std");

const dergdrive = @import("dergdrive");

const Chunk = @import("Chunk.zig");

const VersionChunk = @This();

pub const header_title = "vers";
pub const content_size = 2 * @sizeOf(u8) + @sizeOf(u16);

back_chunk: Chunk,
version: std.SemanticVersion,

pub fn fromChunk(chunk: Chunk) VersionChunk {
    return .{
        .back_chunk = chunk,
        .version = .{
            .major = @intCast(std.mem.readInt(u8, chunk.data[0..@sizeOf(u8)], .little)),
            .minor = @intCast(std.mem.readInt(u8, chunk.data[@sizeOf(u8) .. 2 * @sizeOf(u8)], .little)),
            .patch = @intCast(std.mem.readInt(u8, chunk.data[2 * @sizeOf(u8) .. content_size], .little)),
        },
    };
}

pub fn write(self: VersionChunk, version: ?std.SemanticVersion) void {
    const ver: std.SemanticVersion = version orelse .parse(dergdrive.version) catch unreachable;
    std.mem.writeInt(u8, self.back_chunk.data[0..@sizeOf(u8)], @truncate(ver.major), .little);
    std.mem.writeInt(u8, self.back_chunk.data[@sizeOf(u8) .. 2 * @sizeOf(u8)], @truncate(ver.minor), .little);
    std.mem.writeInt(u16, self.back_chunk.data[2 * @sizeOf(u8) .. content_size], @truncate(ver.patch), .little);
}
