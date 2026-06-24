const std = @import("std");

const dergdrive = @import("dergdrive");

const Chunk = @import("Chunk.zig");

const VersionChunk = @This();

pub const header_title = "vers";
pub const content_size = 2 * @sizeOf(u8) + @sizeOf(u16);

back_chunk: Chunk,
version: std.SemanticVersion,
dev: bool,

const EncodedStruct = packed struct {
    major: u8,
    minor: u8,
    patch: u15,
    dev: bool,
};

pub fn fromChunk(chunk: Chunk) VersionChunk {
    var reader = std.Io.Reader.fixed(chunk.data);
    const encoded = reader.takeStruct(EncodedStruct, .little) catch unreachable;
    return .{
        .back_chunk = chunk,
        .version = .{
            .major = encoded.major,
            .minor = encoded.minor,
            .patch = encoded.patch,
        },
        .dev = encoded.dev,
    };
}

pub fn write(self: VersionChunk, version: ?std.SemanticVersion) void {
    const ver: std.SemanticVersion = version orelse std.SemanticVersion.parse(dergdrive.version) catch unreachable;
    const encoded: EncodedStruct = .{
        .major = @truncate(ver.major),
        .minor = @truncate(ver.minor),
        .patch = @truncate(ver.patch),
        .dev = ver.build != null,
    };

    var writer = std.Io.Writer.fixed(self.back_chunk.data[0..content_size]);
    writer.writeStruct(encoded, .little) catch unreachable;
}

test "encoded struct size" {
    try std.testing.expectEqual(4, @sizeOf(EncodedStruct));
}
