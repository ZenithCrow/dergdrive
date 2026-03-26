const std = @import("std");

const sync = @import("dergdrive").proto.sync;
const RequestChunk = sync.RequestChunk;

const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");

const RequestStorage = @This();

pub const RequestParams = union {
    file_post: struct {
        dest: sync.DestChunk,
    },
    file_new: struct {
        length: sync.DestChunk,
    },
};

pub const Response = union {
    file_post: void,
    file_new: struct {
        dest: sync.DestChunk,
    },
};

pub const Request = struct {
    id: RequestChunk.IdT,
    req_type: RequestChunk.RequestType,
    resp_code: RequestChunk.ResponseCode = .resp_no_error,
    n_sent: usize = 0,
    req: RequestParams,
    resp: ?Response = null,
};

id_supply: RequestChunk.IdSupplier = .{},
pending_reqs: std.AutoArrayHashMap(RequestChunk.IdT, Request),
finished_reqs: std.AutoArrayHashMap(RequestChunk.IdT, Request),

pub fn newPushFileNew(self: *RequestStorage) std.mem.Allocator.Error!RequestChunk.IdT {
    const req_id = self.id_supply.takeId();

    try self.pending_reqs.putNoClobber(req_id, .{
        .id = req_id,
        .req_type = .file_new,
        .req = undefined,
    });

    return req_id;
}
