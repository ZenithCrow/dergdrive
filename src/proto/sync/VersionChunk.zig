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

pub fn set(self: *VersionChunk, version: ?std.SemanticVersion) void {
    self.version = version orelse std.SemanticVersion.parse(dergdrive.version) catch unreachable;
}

pub fn write(self: VersionChunk) void {
    const encoded: EncodedStruct = .{
        .major = @truncate(self.version.major),
        .minor = @truncate(self.version.minor),
        .patch = @truncate(self.version.patch),
        .dev = self.version.build != null,
    };

    var writer = std.Io.Writer.fixed(self.back_chunk.data[0..content_size]);
    writer.writeStruct(encoded, .little) catch unreachable;
}

test "encoded struct size" {
    try std.testing.expectEqual(4, @sizeOf(EncodedStruct));
}
