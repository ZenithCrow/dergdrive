const std = @import("std");
const File = std.Io.File;
const Dir = std.Io.Dir;

const dergdrive = @import("dergdrive");
const sync = dergdrive.proto.sync;
const track = dergdrive.client.track;
const IncludeTree = track.IncludeTree;
const SyncOp = track.SyncOp;
const Manifest = track.Manifest;
const FileRecordMap = track.FileRecordMap;

const pipe_adapter = @import("pipe_adapter.zig");
const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const FileReader = @This();

raw_file_adapter: *pipe_adapter.RawFilePipeAdapter,
req_stor: *RequestStorage,

pub const PipeFileError = File.LengthError || File.Reader.Error;
pub const PipeDirError = error{IncompleteTransaction} || std.mem.Allocator.Error;

const log = std.log.scoped(.@"client/transmit/FileReader");

pub const open_file_error_notice = "Couldn't open file \"{s}\" due to error: {t}.";
pub const pipe_file_error_notice = "Failed to pipe file \"{s}\" due to error: {t}.";
pub const sync_file_error_notice = "Failed to sync file \"{s}\" due to error: {t}.";
pub const iter_dir_error_notice = "Couldn't properly iterate directory due to error: {t}.";
pub const open_dir_error_notice = "Couldn't open directory \"{s}\" due to error {t}.";
pub const dir_transaction_error_notice = "Transaction of directory \"{s}\" is only partially successful.";

pub fn pipeFile(self: *FileReader, file: File, req_id: sync.RequestChunk.IdT, io: std.Io) PipeFileError!void {
    var piped_size: usize = 0;
    const file_size = try file.length(io);
    var reader = file.reader(io, &.{});

    {
        try self.req_stor.reqs_lock.lock(io);
        defer self.req_stor.reqs_lock.unlock(io);

        const req = self.req_stor.reqs.getPtr(req_id).?;
        switch (req.req_type) {
            .file_new => req.req.file_new.length.writeFileNewRequest(file_size),
            else => {},
        }
    }

    while (piped_size < file_size) {
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

        rf_chunk_buf.req_id = req_id;

        const bytes_read = reader.interface.readSliceShort(rf_chunk_buf.chunk_buf.buf) catch {
            //  TODO: handle specific error
            //  TODO: possibly send a cancel upload request for this file, so that partial uploads do not occur
            return reader.err.?;
        };

        {
            try rf_chunk_buf.chunk_buf.w_lock.lock(io);
            defer rf_chunk_buf.chunk_buf.w_lock.unlock(io);

            rf_chunk_buf.chunk_buf.data_len = bytes_read;
            log.debug("chunk data len: {d}", .{rf_chunk_buf.chunk_buf.data_len});
        }

        piped_size += bytes_read;
    }
}

/// if not null, `dir` must be opened with iterate flag
pub fn pipeDir(self: *FileReader, dir: Dir, io: std.Io) PipeDirError!void {
    var has_error: bool = false;
    var dir_iter = dir.iterate();
    while (dir_iter.next(io) catch |err| {
        log.err(iter_dir_error_notice, .{err});
        return PipeDirError.IncompleteTransaction;
    }) |entry| {
        switch (entry.kind) {
            .file => {
                const file = dir.openFile(io, entry.name, .{}) catch |err| {
                    log.err(open_file_error_notice, .{ entry.name, err });
                    has_error = true;
                    continue;
                };
                defer file.close(io);

                log.info("push file: {s}", .{entry.name});
                // self.pipeFile(file, try self.req_stor.newPushFileNew()) catch |err| {
                //     log.err(pipe_file_error_notice, .{ entry.name, err });
                //     has_error = true;
                //     continue;
                // };
            },
            .directory => {
                var sub_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch |err| {
                    log.err(open_dir_error_notice, .{ entry.name, err });
                    has_error = true;
                    continue;
                };
                defer sub_dir.close(io);

                self.pipeDir(sub_dir, io) catch |err| switch (err) {
                    PipeDirError.OutOfMemory => return err,
                    PipeDirError.IncompleteTransaction => {
                        log.warn(dir_transaction_error_notice, .{entry.name});
                        has_error = true;
                        continue;
                    },
                };
            },
            else => continue,
        }
    }

    if (has_error)
        return PipeDirError.IncompleteTransaction;
}
