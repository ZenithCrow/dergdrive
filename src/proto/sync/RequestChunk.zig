const std = @import("std");
const Mutex = std.Io.Mutex;

const Chunk = @import("Chunk.zig");
const SyncMessage = @import("SyncMessage.zig");

const RequestChunk = @This();

pub const header_title = "rqst";
pub const IdT = u32;
pub const id_size = @sizeOf(IdT);
pub const request_type_size = @sizeOf(RequestType);
pub const resp_code_size = @sizeOf(RespCodeTagT);
pub const content_size = id_size + request_type_size + resp_code_size;

pub const IdSupplierRole = enum {
    client,
    server,
};

pub fn IdSupplier(role: IdSupplierRole) type {
    return struct {
        pub const InternalIdT = @Int(.unsigned, @typeInfo(IdT).int.bits - 1);
        pub const reserved_failure_id = std.math.maxInt(InternalIdT);

        id_rw_lock: Mutex,
        next_id: InternalIdT,

        pub const init: @This() = .{
            .id_rw_lock = .init,
            .next_id = 0,
        };

        pub fn takeId(self: *@This(), io: std.Io) IdT {
            self.id_rw_lock.lockUncancelable(io);
            defer self.id_rw_lock.unlock(io);

            const id = self.next_id;
            self.next_id +%= 1;

            if (self.next_id == reserved_failure_id)
                self.next_id +%= 1;

            return switch (comptime role) {
                .client => @intCast(id),
                .server => @as(IdT, @intCast(id)) + 1 << (@typeInfo(IdT).int.bits - 1),
            };
        }
    };
}

pub const RequestTagT = u16;
pub const RequestType = enum(RequestTagT) {
    vol_add = 1,
    vol_delete,
    mfest_fetch,
    mfest_post,
    chunk_new,
    chunk_update,
    chunks_fetch,
    chunks_del,
    unit_abort,
    trans_abort,
    _,
};

pub const RespCodeTagT = u16;
pub const ResponseCode = enum(RespCodeTagT) {
    is_request = 1,
    ok,
    generic_error,
    _,

    pub const resp_no_error: ResponseCode = .is_request;
};

back_chunk: Chunk,
id: IdT,
request_type: RequestType,
resp_code: ResponseCode = .is_request,

pub fn fromChunk(chunk: Chunk) RequestChunk {
    const id = std.mem.readInt(IdT, chunk.data[0..id_size], .little);
    const req_type_num = std.mem.readInt(RequestTagT, chunk.data[id_size .. id_size + request_type_size], .little);
    const resp_code_num = std.mem.readInt(RespCodeTagT, chunk.data[id_size + request_type_size .. id_size + request_type_size + resp_code_size], .little);

    return .{
        .back_chunk = chunk,
        .id = id,
        .request_type = @enumFromInt(req_type_num),
        .resp_code = @enumFromInt(resp_code_num),
    };
}

pub fn write(self: RequestChunk) void {
    std.mem.writeInt(IdT, self.back_chunk.data[0..id_size], self.id, .little);
    std.mem.writeInt(RequestTagT, self.back_chunk.data[id_size .. id_size + request_type_size], @as(RequestTagT, @intFromEnum(self.request_type)), .little);
    std.mem.writeInt(RespCodeTagT, self.back_chunk.data[id_size + request_type_size .. id_size + request_type_size + resp_code_size], @as(RespCodeTagT, @intFromEnum(self.resp_code)), .little);
}
