const std = @import("std");
const File = std.fs.File;
const Dir = std.fs.Dir;

const sync = @import("dergdrive").proto.sync;
const track = @import("dergdrive").client.track;
const IncludeTree = track.IncludeTree;
const SyncOp = track.SyncOp;
const Manifest = track.Manifest;

const pipe_adapter = @import("pipe_adapter.zig");
const RawFileChunkBuffer = @import("RawFileChunkBuffer.zig");
const RequestStorage = @import("RequestStorage.zig");

const FileReader = @This();

raw_file_adapter: *pipe_adapter.RawFilePipeAdapter,
req_stor: *RequestStorage,

pub const PipeFileError = File.GetEndPosError || File.ReadError;
pub const SyncFileError = error{
    NoOp,
    NoPushDeletedPullNew,
    IllegalCombination,
    NoPushNewPullDeleted,
} || std.mem.Allocator.Error || PipeFileError;
pub const SyncDirError = error{};

fn pipeFile(self: *FileReader, file: File, req_id: sync.RequestChunk.IdT) PipeFileError!void {
    var piped_size: usize = 0;
    const file_size = try file.getEndPos();
    var reader = file.reader(&.{});

    const req = self.req_stor.pending_reqs.getPtr(req_id).?;
    switch (req.req_type) {
        .file_new => req.req.file_new.length.writeFileNewRequest(file_size),
        else => {},
    }

    while (piped_size < file_size) {
        const rf_chunk_buf: *RawFileChunkBuffer = self.raw_file_adapter.claimChunkBuf(.write);
        defer self.raw_file_adapter.unclaimChunkBuf(rf_chunk_buf, .write);

        rf_chunk_buf.req_id = req_id;

        const write_buf = rf_chunk_buf.chunk_buf.getBuf();

        const bytes_read = reader.interface.readSliceShort(write_buf) catch {
            //  TODO: handle specific error
            //  TODO: possibly send a cancel upload request for this file, so that partial uploads do not occur
            return reader.err.?;
        };

        {
            rf_chunk_buf.chunk_buf.w_lock.lock();
            defer rf_chunk_buf.chunk_buf.w_lock.unlock();

            rf_chunk_buf.chunk_buf.data_len = bytes_read;
        }

        piped_size += bytes_read;
    }
}

pub fn syncFile(self: *FileReader, subpath: []const u8, file: ?File, sync_op: SyncOp, mfest_records: @FieldType(Manifest, "file_records")) SyncFileError!void {
    const file_record = mfest_records.get(.borrowed(subpath));
    if (file == null) {
        if (file_record) |fr| {
            _ = fr;
            switch (@as(u2, @intFromBool(sync_op.push.deleted)) << 1 | @as(u2, @intFromBool(sync_op.pull.new))) {
                0b00 => return SyncFileError.NoPushDeletedPullNew,
                0b01 => {
                    //  TODO: pull file
                },
                0b10 => {
                    //  TODO: delete file on server
                },
                0b11 => return SyncFileError.IllegalCombination,
            }
        } else return SyncFileError.NoOp;
    } else if (file_record == null) {
        switch (@as(u2, @intFromBool(sync_op.push.new)) << 1 | @as(u2, @intFromBool(sync_op.pull.deleted))) {
            0b00 => return SyncFileError.NoPushNewPullDeleted,
            0b01 => {
                //  TODO: delele local file
            },
            0b10 => {
                try self.pipeFile(file.?, try self.req_stor.newPushFileNew());
            },
            0b11 => return SyncFileError.IllegalCombination,
        }
    }
}

//pub fn syncDir(self: *FileReader, subpath: []const u8, dir: Dir, sync_op: SyncOp) SyncDirError!void {}

test "huh" {
    try std.testing.expect(true);
}
