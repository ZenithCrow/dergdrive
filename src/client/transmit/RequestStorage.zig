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
    finished: bool = false,
};

id_supply: RequestChunk.IdSupplier,
reqs: std.array_hash_map.Auto(RequestChunk.IdT, Request),
reqs_lock: std.Io.Mutex,

reqs_piped: usize = 0,
reqs_complete: usize = 0,
reqs_complete_lock: std.Io.Mutex = .init,
reqs_complete_cond: std.Io.Condition = .init,

pub const init: @This() = .{
    .id_supply = .init,
    .reqs = .empty,
    .reqs_lock = .init,
};

pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
    self.reqs.deinit(allocator);
}

pub fn newPushFileNew(self: *RequestStorage, allocator: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!RequestChunk.IdT {
    const old_cancel_protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(old_cancel_protection);

    const req_id = self.id_supply.takeId(io);

    self.reqs_lock.lock(io) catch unreachable;
    defer self.reqs_lock.unlock(io);

    try self.reqs.putNoClobber(allocator, req_id, .{
        .id = req_id,
        .req_type = .file_new,
        .req = .{ .file_new = undefined },
    });

    return req_id;
}
