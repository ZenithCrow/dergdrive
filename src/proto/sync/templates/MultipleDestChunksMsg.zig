const std = @import("std");

const dergdrive = @import("dergdrive");
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const sync = dergdrive.proto.sync;

pub const Error = error{UnsupportedRequestType} || sync.Chunk.CreateError;

const MultipleDestChunksMsg = @This();

msg_container: sync.SyncMessage,

pub fn init(buf: []u8, query: []const FileRecordMap.FileChunk, req_type: sync.RequestChunk.RequestType, id: sync.RequestChunk.IdT) Error!MultipleDestChunksMsg {
    var sync_msg: sync.SyncMessage = .{ .msg_buf = buf };
    var data_buf = sync_msg.dataBuf();

    var rq_chunk = try sync.Chunk.createChunk(sync.RequestChunk, data_buf);
    rq_chunk.id = id;
    rq_chunk.request_type = switch (req_type) {
        .chunks_del, .chunks_fetch => req_type,
        else => return Error.InsufficientBufferSpace,
    };
    rq_chunk.resp_code = .resp_no_error;
    rq_chunk.write();

    data_buf = data_buf[sync.header.header_size + sync.RequestChunk.content_size ..];

    for (query) |f| {
        var dest_chunk = try sync.Chunk.createChunk(sync.DestChunk, data_buf);
        const q: sync.DestChunk.Query = .{
            .blk_id = f.blk_id,
            .offset = f.blk_offset,
            .prev_len = f.encoded_len,
        };
        dest_chunk.valuesFromQuery(q);
        dest_chunk.write();

        data_buf = data_buf[sync.header.header_size + sync.DestChunk.content_size ..];
    }

    _ = sync.Chunk.createChunk(sync.BreakChunk, data_buf) catch {};

    sync_msg.resetSizeHeader();
    sync_msg.updateHeader() catch unreachable;

    return .{
        .msg_container = sync_msg,
    };
}

test "msg size" {
    var buf: [1024]u8 = undefined;
    const allocator = std.testing.allocator;
    const n = 20;
    const query = try allocator.alloc(FileRecordMap.FileChunk, n);
    defer allocator.free(query);

    const mdcm: MultipleDestChunksMsg = try .init(&buf, query, .chunks_del, 0);
    const computed_dests_len = n * (sync.header.header_size + sync.DestChunk.content_size);
    const actual_dests_len = (mdcm.msg_container.getMsgSize() catch unreachable) - (2 * sync.header.header_size + sync.RequestChunk.content_size);
    try std.testing.expectEqual(computed_dests_len, actual_dests_len);
}
