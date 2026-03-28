const std = @import("std");
const File = std.fs.File;
const Dir = std.fs.Dir;

const sync = @import("dergdrive").proto.sync;
const track = @import("dergdrive").client.track;
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

pub const PipeFileError = File.GetEndPosError || File.ReadError;
pub const PipeDirError = error{IncompleteTransaction};
pub const FlagError = error{
    NoOp,
    NoPushDeletedPullNew,
    IllegalCombination,
    NoPushNewPullDeleted,
};
pub const SyncFileError = FlagError || std.mem.Allocator.Error || PipeFileError || File.StatError;
pub const SyncDirError = PipeDirError || FlagError || std.mem.Allocator.Error;

const log = std.log.scoped(.@"client/transmit/FileReader");

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

const iter_dir_error_notice = "Couldn't properly iterate directory due to error: {t}.";
const open_file_error_notice = "Couldn't open file \"{s}\" due to error: {t}.";
const pipe_file_error_notice = "Failed to pipe file \"{s}\" due to error: {t}.";
const open_dir_error_notice = "Couldn't open directory \"{s}\" due to error {t}.";
const dir_transaction_error_notice = "Transaction of directory \"{s}\" is only partially successful.";

/// dir has to be opened with iterate flags
fn pipeDir(self: *FileReader, dir: Dir) PipeDirError!void {
    var has_error: bool = false;
    var dir_iter = dir.iterate();
    while (dir_iter.next() catch |err| {
        log.err(iter_dir_error_notice, .{err});
        return PipeDirError.IncompleteTransaction;
    }) |entry| {
        switch (entry.kind) {
            .file => {
                const file = dir.openFile(entry.name, .{}) catch |err| {
                    log.err(open_file_error_notice, .{ entry.name, err });
                    has_error = true;
                    continue;
                };
                defer file.close();

                self.pipeFile(file, try self.req_stor.newPushFileNew()) catch |err| {
                    log.err(pipe_file_error_notice, .{ entry.name, err });
                    has_error = true;
                    continue;
                };
            },
            .directory => {
                const sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch |err| {
                    log.err(open_dir_error_notice, .{ entry.name, err });
                    has_error = true;
                    continue;
                };
                defer sub_dir.close();

                self.pipeDir(sub_dir) catch {
                    log.warn(dir_transaction_error_notice, .{entry.name});
                    has_error = true;
                };
            },
            else => continue,
        }
    }

    if (has_error)
        return PipeDirError.IncompleteTransaction;
}

fn unitIsFile(comptime UT: type) bool {
    const type_err = "unit must be either optional Dir or File type";
    return switch (@typeInfo(UT)) {
        .optional => |opt| switch (opt.child) {
            File => true,
            Dir => false,
            else => @compileError(type_err),
        },
        else => @compileError(type_err),
    };
}

/// if unit is dir, it has to be opened with with iterate flags
fn syncUnit(
    self: *FileReader,
    subpath: []const u8,
    unit: anytype,
    sync_op: SyncOp,
    mfest_records: *FileRecordMap,
    allocator: std.mem.Allocator,
) (if (unitIsFile(@TypeOf(unit))) SyncFileError else SyncDirError)!void {
    const is_file = comptime unitIsFile(@TypeOf(unit));

    const unit_record = if (is_file) mfest_records.file_records.getPtr(.borrowed(subpath)) else mfest_records.getDir(subpath);
    if (unit == null) {
        if (if (is_file) unit_record != null else unit_record.len > 0) {
            switch (@as(u2, @intFromBool(sync_op.push.deleted)) << 1 | @as(u2, @intFromBool(sync_op.pull.new))) {
                0b00 => return SyncFileError.NoPushDeletedPullNew,
                0b01 => {
                    //  TODO: pull unit
                },
                0b10 => {
                    //  TODO: delete unit on server
                },
                0b11 => return SyncFileError.IllegalCombination,
            }
        } else return SyncFileError.NoOp;
    } else if (if (is_file) unit_record == null else unit_record.len == 0) {
        switch (@as(u2, @intFromBool(sync_op.push.new)) << 1 | @as(u2, @intFromBool(sync_op.pull.deleted))) {
            0b00 => return SyncFileError.NoPushNewPullDeleted,
            0b01 => {
                //  TODO: delele unit locally
            },
            0b10 => if (is_file) try self.pipeFile(unit.?, try self.req_stor.newPushFileNew()) else try self.pipeDir(unit.?),
            0b11 => return SyncFileError.IllegalCombination,
        }
    } else {
        switch (@as(u2, @intFromBool(sync_op.push.force)) < 1 | @as(u2, @intFromBool(sync_op.pull.force))) {
            0b00 => {
                if (is_file) {
                    const stat = try unit.?.stat();
                    if (stat.mtime > unit_record.?.tstamp.mod_time) {
                        try self.pipeFile(unit.?, try self.req_stor.newPushFileNew());
                    } else if (stat.mtime < unit_record.?.tstamp.mod_time) {
                        //  TODO: pull unit
                    }
                } else {
                    var has_error: bool = false;
                    var dir_iter: Dir.Iterator = unit.?.iterate();
                    while (dir_iter.next() catch |err| {
                        log.err(iter_dir_error_notice, .{err});
                        return SyncDirError.IncompleteTransaction;
                    }) |entry| {
                        switch (entry.kind) {
                            .file => {
                                const file: File = unit.openFile(entry.name) catch |err| {
                                    log.err(open_file_error_notice, .{ entry.name, err });
                                    has_error = true;
                                    continue;
                                };
                                defer file.close();

                                const subpath_new = try std.mem.join(allocator, "/", &.{ subpath, entry.name });
                                defer allocator.free(subpath_new);

                                self.syncFile(subpath_new, file, sync_op, mfest_records, allocator) catch |err| switch (err) {
                                    SyncFileError.IllegalCombination, SyncFileError.NoOp, SyncFileError.NoPushDeletedPullNew, SyncFileError.NoPushNewPullDeleted => continue,
                                    SyncFileError.OutOfMemory => return err,
                                    else => {
                                        log.err("Failed to sync file \"{s}\" due to error: {t}.", .{ subpath_new, err });
                                        has_error = true;
                                        continue;
                                    },
                                };
                            },
                            .directory => {
                                const dir: Dir = unit.openDir(entry.name) catch |err| {
                                    log.err(open_dir_error_notice, .{ entry.name, err });
                                    has_error = true;
                                    continue;
                                };
                                defer dir.close();

                                const subpath_new = try std.mem.join(allocator, "/", &.{ subpath, entry.name });
                                defer allocator.free(subpath_new);

                                self.syncDir(subpath_new, dir, sync_op, mfest_records, allocator) catch |err| switch (err) {
                                    SyncDirError.IncompleteTransaction => {
                                        log.warn(dir_transaction_error_notice, .{subpath_new});
                                        has_error = true;
                                        continue;
                                    },
                                    SyncDirError.OutOfMemory => return err,
                                    else => continue,
                                };
                            },
                        }
                    }

                    if (has_error)
                        return SyncDirError.IncompleteTransaction;
                }
            },
            0b01 => {
                //  TODO: pull unit
            },
            0b10 => if (is_file) try self.pipeFile(unit.?, try self.req_stor.newPushFileNew()) else try self.pipeDir(unit.?),
            0b11 => return SyncFileError.IllegalCombination,
        }
    }
}

pub inline fn syncFile(
    self: *FileReader,
    subpath: []const u8,
    file: ?File,
    sync_op: SyncOp,
    mfest_records: *FileRecordMap,
    allocator: std.mem.Allocator,
) SyncFileError!void {
    try self.syncUnit(subpath, file, sync_op, mfest_records, allocator);
}

pub inline fn syncDir(
    self: *FileReader,
    subpath: []const u8,
    dir: ?Dir,
    sync_op: SyncOp,
    mfest_records: *FileRecordMap,
    allocator: std.mem.Allocator,
) SyncDirError!void {
    try self.syncUnit(subpath, dir, sync_op, mfest_records, allocator);
}
