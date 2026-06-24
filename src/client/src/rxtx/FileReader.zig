const std = @import("std");
const File = std.Io.File;
const Dir = std.Io.Dir;

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const FileRecordMap = dergdrive.client.track.FileRecordMap;

const pipe_adapter = @import("pipe_adapter.zig");
const PrioRequest = @import("PrioRequest.zig");
const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const FileReader = @This();

raw_file_adapter: *pipe_adapter.RawFilePipeAdapter,
req_stor: *RequestStorage,
prio_req: *PrioRequest,

pub const PipeFileError = error{UnitAbortFailed} || File.LengthError || File.Reader.Error || std.mem.Allocator.Error || PrioRequest.CreateReqError;

const log = std.log.scoped(.@"client/transmit/FileReader");

pub const open_file_error_notice = "Couldn't open file \"{s}\" due to error: {t}.";
pub const pipe_file_error_notice = "Failed to pipe file \"{s}\" due to error: {t}.";
pub const sync_file_error_notice = "Failed to sync file \"{s}\" due to error: {t}.";

pub const PipeInfo = struct {
    path: []const u8,
    dests: []const FileRecordMap.FileChunk,
};

pub fn pipeFile(self: *FileReader, file: File, pipe_info: PipeInfo, gpa: std.mem.Allocator, io: std.Io) PipeFileError!void {
    self.pipeFileErrorNowrap(file, pipe_info, gpa, io) catch |err| {
        log.warn("Transaction of file \"{s}\" wasn't successful due to error: {t}.", .{ pipe_info.path, err });

        switch (err) {
            PipeFileError.OutOfMemory, PipeFileError.UnitAbortFailed => return err,
            else => {
                log.warn("Sending a cancel upload request for file \"{s}\"", .{pipe_info.path});

                const file_req_ids = self.req_stor.gatherFileReqIds(pipe_info.path, gpa, io) catch return PipeFileError.UnitAbortFailed;
                errdefer gpa.free(file_req_ids);

                const req_id = self.req_stor.unitAbortReq(file_req_ids, gpa, io) catch return PipeFileError.UnitAbortFailed;
                errdefer _ = self.req_stor.removeRequest(req_id, io);

                self.prio_req.unitAbortReq(file_req_ids, req_id, io) catch return PipeFileError.UnitAbortFailed;
            },
        }
    };
}

fn pipeFileErrorNowrap(self: *FileReader, file: File, pipe_info: PipeInfo, gpa: std.mem.Allocator, io: std.Io) PipeFileError!void {
    var piped_size: u64 = 0;
    const file_size = try file.length(io);
    var reader = file.reader(io, &.{});

    var idx_sent: usize = 0;

    while (piped_size < file_size) : (idx_sent += 1) {
        {
            try self.req_stor.reqs_complete_lock.lock(io);
            defer self.req_stor.reqs_complete_lock.unlock(io);

            self.req_stor.reqs_piped += 1;
        }

        const rf_chunk_buf: *RawFileChunkBuffer = try self.raw_file_adapter.claimChunkBuf(.write, io);
        log.debug("claimed chunk buffer", .{});
        defer {
            self.raw_file_adapter.unclaimChunkBuf(rf_chunk_buf, .write, io);
            log.debug("unclaimed chunk buffer", .{});
        }

        const bytes_read = reader.interface.readSliceShort(rf_chunk_buf.chunk_buf.buf) catch {
            switch (reader.err.?) {
                std.Io.Cancelable.Canceled => |err| return err,
                else => |err| {
                    log.warn("Failed to read file \"{s}\" due to error: {t}.", .{ pipe_info.path, err });
                    return err;
                },
            }
        };

        {
            try rf_chunk_buf.chunk_buf.w_lock.lock(io);
            defer rf_chunk_buf.chunk_buf.w_lock.unlock(io);

            rf_chunk_buf.chunk_buf.data_len = bytes_read;
            log.debug("chunk data len: {d}", .{rf_chunk_buf.chunk_buf.data_len});
        }

        const local_fi: FileRecordMap.FileChunk.LocalFileInfo = .{
            .file_offset = piped_size,
            .real_len = @intCast(bytes_read),
        };

        // create file_new requests if run out of existing file chunks
        rf_chunk_buf.req_id = if (pipe_info.dests.len == 0 or idx_sent > pipe_info.dests.len - 1)
            try self.req_stor.chunkNewReq(pipe_info.path, local_fi, gpa, io)
        else blk: {
            const file_chunk = &pipe_info.dests[idx_sent];
            const dest: sync.DestChunk.Query = .{
                .offset = file_chunk.blk_offset,
                .prev_len = file_chunk.encoded_len,
                .blk_id = file_chunk.blk_id,
            };
            break :blk try self.req_stor.chunkUpdateReq(pipe_info.path, dest, local_fi, gpa, io);
        };

        piped_size += bytes_read;
    }

    // truncate unused file chunks
    if (idx_sent < pipe_info.dests.len) {
        const req_id = try self.req_stor.chunksDelReq(pipe_info.path, pipe_info.dests, idx_sent, gpa, io);
        try self.prio_req.chunksDelReq(pipe_info.dests, req_id, io);
    }
}
