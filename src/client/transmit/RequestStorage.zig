const std = @import("std");
pub const CreateFilePushReqError = std.mem.Allocator.Error;

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const RequestChunk = sync.RequestChunk;
const shared_slice = dergdrive.util.shared_slice;

const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");

const RequestStorage = @This();

pub const RequestParams = union(RequestChunk.RequestType) {
    vol_add,
    vol_delete,
    mfest_fetch,
    mfest_post,
    files_request: void,
    file_new: struct {
        path: *shared_slice.SharedString,
    },
    file_push: struct {
        path: *shared_slice.SharedString,
        dest: sync.DestChunk,
    },
    file_delete: void,
};

pub const Response = union(RequestChunk.RequestType) {
    vol_add,
    vol_delete,
    mfest_fetch,
    mfest_post,
    files_request,
    file_new: struct {
        dest: sync.DestChunk,
    },
    file_push: struct {
        reloc: sync.DestChunk,
    },
    file_delete: void,
};

pub const Request = struct {
    id: RequestChunk.IdT,
    resp_code: RequestChunk.ResponseCode = .resp_no_error,
    n_sent: usize = 0,
    query: RequestParams,
    resp: ?Response = null,
    finished: bool = false,
};

id_supply: RequestChunk.IdSupplier,
reqs: std.array_hash_map.Auto(RequestChunk.IdT, Request),
string_stor: shared_slice.SharedStringStorage,
lock: std.Io.Mutex,

reqs_piped: usize = 0,
reqs_complete: usize = 0,
reqs_complete_lock: std.Io.Mutex = .init,
reqs_complete_cond: std.Io.Condition = .init,

pub const init: @This() = .{
    .id_supply = .init,
    .reqs = .empty,
    .string_stor = .empty,
    .lock = .init,
};

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    self.reqs.deinit(gpa);
    self.string_stor.deinitAll(gpa);
}

pub fn createFileNewReq(self: *RequestStorage, path: []const u8, gpa: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error!RequestChunk.IdT {
    const req_id = self.id_supply.takeId(io);

    self.lock.lockUncancelable(io);
    defer self.lock.unlock(io);

    var sh_str = try self.string_stor.getOrPut(path, gpa);

    try self.reqs.putNoClobber(gpa, req_id, .{
        .id = req_id,
        .query = .{ .file_new = .{
            .path = sh_str.ref(),
        } },
    });

    return req_id;
}

pub fn createFilePushReq(self: *RequestStorage, path: []const u8, dest: sync.DestChunk, gpa: std.mem.Allocator, io: std.Io) CreateFilePushReqError!RequestChunk.IdT {
    const req_id = self.id_supply.takeId(io);

    self.lock.lockUncancelable(io);
    defer self.lock.unlock(io);

    var sh_str = try self.string_stor.getOrPut(path, gpa);

    try self.reqs.putNoClobber(gpa, req_id, .{
        .id = req_id,
        .query = .{ .file_push = .{
            .path = sh_str.ref(),
            .dest = dest,
        } },
    });

    return req_id;
}
