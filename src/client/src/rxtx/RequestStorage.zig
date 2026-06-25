const std = @import("std");

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const RequestChunk = sync.RequestChunk;
const shared_slice = dergdrive.util.shared_slice;
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const Chunk = sync.Chunk;

const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");

const RequestStorage = @This();

pub const WaitForError = error{ SubsystemFail, QueueFull } || std.Io.Cancelable;

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
    trans_abort,
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
    chunks_fetch,
    chunks_del,
    unit_abort,
    trans_abort,
};

pub const HeadlessResponse = union(Chunk.ChunkType) {
    sync_message,
    request,
    destination,
    payload,
    @"break",
    encrypted_payload,
    key_xchg: sync.KeyXchgChunk,
    version: sync.VersionChunk,
};

pub const Request = struct {
    id: RequestChunk.IdT,
    resp_code: RequestChunk.ResponseCode = .resp_no_error,
    n_sent: usize = 0,
    query: Query,
    resp: ?Response = null,
    finished: bool = false,
};

pub const WQResultIdentifier = enum {
    by_id,
    by_resp_type,
};

pub const WaitQuery = struct {
    received: bool,
    result: union(WQResultIdentifier) {
        by_id: RequestChunk.IdT,
        by_resp_type: HeadlessResponse,
    },
};

pub const WaitQueryVec = struct {
    vec: []WaitQuery,
    state_changes: usize = 0,
};

const wait_q_vecs_capacity = 4;

id_supply: RequestChunk.IdSupplier(.client),
reqs: std.array_hash_map.Auto(RequestChunk.IdT, Request),
string_stor: shared_slice.SharedStringStorage,
req_stor_lock: std.Io.Mutex,

wait_q_vecs: [wait_q_vecs_capacity]?*WaitQueryVec,
subsystem_fail: bool,
wait_q_lock: std.Io.Mutex,
wait_q_cond: std.Io.Condition,

pub const init: RequestStorage = .{
    .id_supply = .init,
    .reqs = .empty,
    .string_stor = .empty,
    .req_stor_lock = .init,
    .wait_q_vecs = blk: {
        var empty: [wait_q_vecs_capacity]?*WaitQueryVec = undefined;
        for (&empty) |*e| {
            e.* = null;
        }
        break :blk empty;
    },
    .wait_q_lock = .init,
    .subsystem_fail = false,
    .wait_q_cond = .init,
};

pub fn deinit(self: *RequestStorage, gpa: std.mem.Allocator) void {
    self.reqs.deinit(gpa);
    self.string_stor.deinitAll(gpa);
}

pub fn waitFor(self: *RequestStorage, wqv: *WaitQueryVec, io: std.Io, out_state_changes: *usize) WaitForError!void {
    try self.wait_q_lock.lock(io);
    defer self.wait_q_lock.unlock(io);

    const idx = for (&self.wait_q_vecs, 0..) |vec, i| {
        if (vec == null)
            break i;
    } else return WaitForError.QueueFull;

    self.wait_q_vecs[idx] = wqv;

    while (!self.subsystem_fail and wqv.state_changes == 0)
        try self.wait_q_cond.wait(io, &self.wait_q_lock);

    out_state_changes.* = wqv.state_changes;
    self.wait_q_vecs[idx] = null;

    if (self.subsystem_fail)
        return WaitForError.SubsystemFail;
}

pub fn broadcastSubsystemFail(self: *RequestStorage, io: std.Io) void {
    {
        self.wait_q_lock.lockUncancelable(io);
        defer self.wait_q_lock.unlock(io);

        self.subsystem_fail = true;
    }

    self.wait_q_cond.broadcast(io);
}

pub fn broadcastReceived(
    self: *RequestStorage,
    identifier: union(WQResultIdentifier) {
        by_id: RequestChunk.IdT,
        by_resp_type: HeadlessResponse,
    },
    io: std.Io,
) void {
    var broadcast: bool = false;

    {
        self.wait_q_lock.lockUncancelable(io);
        defer self.wait_q_lock.unlock(io);

        for (self.wait_q_vecs) |vec| {
            if (vec) |v| {
                for (v.vec) |*wq| {
                    if (std.meta.activeTag(wq.result) == std.meta.activeTag(identifier)) {
                        if (switch (wq.result) {
                            .by_id => |id| id == identifier.by_id,
                            .by_resp_type => |*rt| blk: {
                                if (std.meta.activeTag(rt.*) == std.meta.activeTag(identifier.by_resp_type)) {
                                    rt.* = identifier.by_resp_type;
                                    break :blk true;
                                }

                                break :blk false;
                            },
                        }) {
                            wq.received = true;
                            broadcast = true;
                            v.state_changes += 1;
                        }
                    }
                }
            }
        }
    }

    if (broadcast)
        self.wait_q_cond.broadcast(io);
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

            self.req_stor_lock.lockUncancelable(io);
            defer self.req_stor_lock.unlock(io);

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

pub fn removeRequest(self: *RequestStorage, id: RequestChunk.IdT, io: std.Io) ?Request {
    self.req_stor_lock.lockUncancelable(io);
    defer self.req_stor_lock.unlock(io);

    const req = self.reqs.get(id);
    _ = self.reqs.swapRemove(id);
    return req;
}

pub fn chunkNewReq(
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

pub fn chunkUpdateReq(
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

pub fn chunksDelReq(
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

pub fn gatherFileReqIds(
    self: *RequestStorage,
    path: []const u8,
    gpa: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error![]const RequestChunk.IdT {
    var id_list: std.ArrayList(RequestChunk.IdT) = .empty;

    self.req_stor_lock.lockUncancelable(io);
    defer self.req_stor_lock.unlock(io);

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

pub fn unitAbortReq(
    self: *RequestStorage,
    req_ids: []const RequestChunk.IdT,
    gpa: std.mem.Allocator,
    io: std.Io,
) std.mem.Allocator.Error!RequestChunk.IdT {
    const req_id = self.id_supply.takeId(io);

    self.req_stor_lock.lockUncancelable(io);
    defer self.req_stor_lock.unlock(io);

    try self.reqs.putNoClobber(gpa, req_id, .{
        .id = req_id,
        .query = .{ .unit_abort = .{
            .file_req_ids = req_ids,
        } },
    });

    return req_id;
}
