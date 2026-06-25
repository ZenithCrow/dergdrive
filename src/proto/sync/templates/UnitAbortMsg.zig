const std = @import("std");

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
pub const Error = sync.Chunk.CreateError;

const UnitAbortMsg = @This();

msg_container: sync.SyncMessage,

pub fn init(buf: []u8, unit_req_ids: []const sync.RequestChunk.IdT, id: sync.RequestChunk.IdT) Error!UnitAbortMsg {
    const sync_msg: sync.SyncMessage = .{ .msg_buf = buf };
    var data_buf = try sync_msg.initRequest(.unit_abort, id);

    var pld_chunk = try sync.Chunk.createChunk(sync.PayloadChunk, data_buf);
    data_buf = data_buf[sync.header.header_size..];

    const pld_len = unit_req_ids.len * @sizeOf(sync.RequestChunk.IdT);
    if (pld_len > data_buf.len)
        return Error.InsufficientBufferSpace;

    pld_chunk.claimBuf(data_buf[0..pld_len]);

    var writer = std.Io.Writer.fixed(pld_chunk.payload);
    for (unit_req_ids) |req_id| {
        writer.writeInt(@TypeOf(req_id), req_id, .little) catch unreachable;
    }

    data_buf = data_buf[pld_len..];
    _ = sync.Chunk.createChunk(sync.BreakChunk, data_buf) catch {};

    sync_msg.containMsgInSizeHeader();
    sync_msg.updateHeader() catch unreachable;

    return .{
        .msg_container = sync_msg,
    };
}

test "correct payload size" {
    var buf: [1024]u8 = undefined;

    const gpa = std.testing.allocator;
    const n = 20;
    const req_ids = try gpa.alloc(sync.RequestChunk.IdT, n);
    defer gpa.free(req_ids);

    const uam: UnitAbortMsg = try .init(&buf, req_ids, 0);
    const computed_req_ids_len = n * @sizeOf(sync.RequestChunk.IdT);
    const actual_req_ids_len = (uam.msg_container.getMsgSize() catch unreachable) - (3 * sync.header.header_size + sync.RequestChunk.content_size);

    try std.testing.expectEqual(computed_req_ids_len, actual_req_ids_len);
}
