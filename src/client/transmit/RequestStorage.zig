const std = @import("std");

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const RequestChunk = sync.RequestChunk;
const shared_slice = dergdrive.util.shared_slice;
const FileRecordMap = dergdrive.client.track.FileRecordMap;

const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");

const RequestStorage = @This();

pub const Query = union(RequestChunk.RequestType) {
    vol_add,
    vol_delete,
    mfest_fetch,
    mfest_post,
    chunk_new: struct {
        path: *shared_slice.SharedString,
        local_fi: FileRecordMap.FileChunk.LocalFileInfo,
    },
    chunk_update: struct {
        path: *shared_slice.SharedString,
        dest: sync.DestChunk.Query,
        local_fi: FileRecordMap.FileChunk.LocalFileInfo,
    },
    chunks_fetch: struct {
        path: *shared_slice.SharedString,
        local_fi: FileRecordMap.FileChunk.LocalFileInfo,
    },
    chunks_del: struct {
        path: *shared_slice.SharedString,
        // only using the DestChunk.Query part
        del_dests: []const FileRecordMap.FileChunk,
        del_start_idx: usize,
    },
    unit_abort: struct {
        file_req_ids: []const RequestChunk.IdT,
    },
    trans_abort: void,
};

pub const Response = union(RequestChunk.RequestType) {
    vol_add,
    vol_delete,
    mfest_fetch,
    mfest_post,
    chunk_new: struct {
        dest: sync.DestChunk.Query,
    },
    chunk_update: struct {
        reloc: sync.DestChunk.Query,
    },
    chunks_fetch: void,
    chunks_del: void,
    unit_abort: void,
    trans_abort: void,
};

pub const Request = struct {
    id: RequestChunk.IdT,
    resp_code: RequestChunk.ResponseCode = .resp_no_error,
    n_sent: usize = 0,
    query: Query,
    resp: ?Response = null,
    finished: bool = false,
};

id_supply: RequestChunk.IdSupplier(.client),
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

fn createChunkReq(
    self: *RequestStorage,
    path: []const u8,
    query: Query,
    gpa: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error!RequestChunk.IdT {
    switch (query) {
        .chunk_new, .chunk_update, .chunks_del, .chunks_fetch => {
            const req_id = self.id_supply.takeId(io);

            self.lock.lockUncancelable(io);
            defer self.lock.unlock(io);

            var sh_str = try self.string_stor.getOrPut(path, gpa);
            var q_mut = query;
            switch (q_mut) {
                .chunk_new => |*q| q.path = sh_str.ref(),
                .chunk_update => |*q| q.path = sh_str.ref(),
                .chunks_del => |*q| q.path = sh_str.ref(),
                .chunks_fetch => |*q| q.path = sh_str.ref(),
                else => unreachable,
            }

            try self.reqs.putNoClobber(gpa, req_id, .{
                .id = req_id,
                .query = q_mut,
            });

            return req_id;
        },
        else => @panic("only chunk request types allowed"),
    }
}

pub fn createChunkNewReq(
    self: *RequestStorage,
    path: []const u8,
    local_fi: FileRecordMap.FileChunk.LocalFileInfo,
    gpa: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error!RequestChunk.IdT {
    return try self.createChunkReq(path, .{ .chunk_new = .{
        .path = undefined,
        .local_fi = local_fi,
    } }, gpa, io);
}

pub fn createChunkUpdateReq(
    self: *RequestStorage,
    path: []const u8,
    dest: sync.DestChunk.Query,
    local_fi: FileRecordMap.FileChunk.LocalFileInfo,
    gpa: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error!RequestChunk.IdT {
    return try self.createChunkReq(path, .{ .chunk_update = .{
        .path = undefined,
        .dest = dest,
        .local_fi = local_fi,
    } }, gpa, io);
}

pub fn createChunksDelReq(
    self: *RequestStorage,
    path: []const u8,
    del_dests: []const FileRecordMap.FileChunk,
    del_start_idx: usize,
    gpa: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error!RequestChunk.IdT {
    return try self.createChunkReq(path, .{ .chunks_del = .{
        .path = undefined,
        .del_dests = del_dests,
        .del_start_idx = del_start_idx,
    } }, gpa, io);
}

pub fn gatherFileReqsIds(self: *RequestStorage, path: []const u8, gpa: std.mem.Allocator, io: std.Io) std.mem.Allocator.Error![]const RequestChunk.IdT {
    var id_list: std.ArrayList(RequestChunk.IdT) = .empty;

    self.lock.lockUncancelable(io);
    defer self.lock.unlock(io);

    for (self.reqs.values()) |val| {
        switch (val.query) {
            .chunk_new => |q| if (std.mem.eql(u8, q.path.slice, path)) try id_list.append(gpa, val.id),
            .chunk_update => |q| if (std.mem.eql(u8, q.path.slice, path)) try id_list.append(gpa, val.id),
            .chunks_del => |q| if (std.mem.eql(u8, q.path.slice, path)) try id_list.append(gpa, val.id),
            .chunks_fetch => |q| if (std.mem.eql(u8, q.path.slice, path)) try id_list.append(gpa, val.id),
            else => {},
        }
    }

    return id_list.items;
}
