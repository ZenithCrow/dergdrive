const std = @import("std");

const Chunk = @import("Chunk.zig");

const BreakChunk = @This();

pub const header_title = "brk!";
pub const content_size = 0;

pub fn fromChunk(_: Chunk) BreakChunk {
    return .{};
}

