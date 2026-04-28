const std = @import("std");
const File = std.fs.File;
const Dir = std.fs.Dir;

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

pub const PipeFileError = File.GetEndPosError || File.ReadError;
pub const PipeDirError = error{IncompleteTransaction} || std.mem.Allocator.Error;
pub const FlagError = error{
    NoOp,
    NoPushDeletedPullNew,
    IllegalCombination,
    NoPushNewPullDeleted,
};
pub const SyncFileError = FlagError || std.mem.Allocator.Error || PipeFileError || File.StatError;
pub const SyncDirError = PipeDirError || FlagError || std.mem.Allocator.Error;

const log = std.log.scoped(.@"client/transmit/FileReader");

const open_file_error_notice = "Couldn't open file \"{s}\" due to error: {t}.";
const pipe_file_error_notice = "Failed to pipe file \"{s}\" due to error: {t}.";
const sync_file_error_notice = "Failed to sync file \"{s}\" due to error: {t}.";
const iter_dir_error_notice = "Couldn't properly iterate directory due to error: {t}.";
const open_dir_error_notice = "Couldn't open directory \"{s}\" due to error {t}.";
const dir_transaction_error_notice = "Transaction of directory \"{s}\" is only partially successful.";

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

/// if not null, `dir` must be opened with iterate flag
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
                var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch |err| {
                    log.err(open_dir_error_notice, .{ entry.name, err });
                    has_error = true;
                    continue;
                };
                defer sub_dir.close();

                self.pipeDir(sub_dir) catch |err| switch (err) {
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

pub fn syncFile(
    self: *FileReader,
    file: ?File,
    sync_op: SyncOp,
    file_record: ?*const FileRecordMap.FileRecord,
) SyncFileError!void {
    if (file == null) {
        if (file_record) |fr| {
            _ = fr;
            switch (@as(u2, @intFromBool(sync_op.push.deleted)) << 1 | @as(u2, @intFromBool(sync_op.pull.new))) {
                0b00 => return SyncFileError.NoPushDeletedPullNew,
                0b01 => {
                    //  TODO: pull fil
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
                //  TODO: delele file locally
            },
            0b10 => try self.pipeFile(file.?, try self.req_stor.newPushFileNew()),
            0b11 => return SyncFileError.IllegalCombination,
        }
    } else {
        switch (@as(u2, @intFromBool(sync_op.push.force)) << 1 | @as(u2, @intFromBool(sync_op.pull.force))) {
            0b00 => {
                const stat = try file.?.stat();
                if (stat.mtime > file_record.?.tstamp.mod_time) {
                    try self.pipeFile(file.?, try self.req_stor.newPushFileNew());
                } else if (stat.mtime < file_record.?.tstamp.mod_time) {
                    //  TODO: pull file
                }
            },
            0b01 => {
                //  TODO: pull file
            },
            0b10 => try self.pipeFile(file.?, try self.req_stor.newPushFileNew()),
            0b11 => return SyncFileError.IllegalCombination,
        }
    }
}

/// if not null, `dir` must be open with iterate flag
pub fn syncDir(
    self: *FileReader,
    subpath: []const u8,
    dir: ?Dir,
    sync_op: SyncOp,
    frmap_dir_iter: FileRecordMap.DirIterator,
    allocator: std.mem.Allocator,
) SyncDirError!void {
    if (dir == null) {
        if (frmap_dir_iter.dir_range.@"0" < frmap_dir_iter.dir_range.@"0") {
            switch (@as(u2, @intFromBool(sync_op.push.deleted)) << 1 | @as(u2, @intFromBool(sync_op.pull.new))) {
                0b00 => return SyncFileError.NoPushDeletedPullNew,
                0b01 => {
                    //  TODO: pull dir recursively
                },
                0b10 => {
                    //  TODO: delete dir recursively on server
                },
                0b11 => return SyncFileError.IllegalCombination,
            }
        } else return SyncFileError.NoOp;
    } else if (frmap_dir_iter.dir_range.@"0" == frmap_dir_iter.dir_range.@"0") {
        switch (@as(u2, @intFromBool(sync_op.push.new)) << 1 | @as(u2, @intFromBool(sync_op.pull.deleted))) {
            0b00 => return SyncFileError.NoPushNewPullDeleted,
            0b01 => {
                //  TODO: delele dir recursively locally
            },
            0b10 => try self.pipeDir(dir.?),
            0b11 => return SyncFileError.IllegalCombination,
        }
    } else {
        switch (@as(u2, @intFromBool(sync_op.push.force)) << 1 | @as(u2, @intFromBool(sync_op.pull.force))) {
            0b00 => {
                const empty_rules: IncludeTree = .{
                    .allocator = undefined,
                    .flat_tree = .{ .map = .empty },
                    .root_dir = undefined,
                    .rules = undefined,
                };

                try self.syncDirApplyRules(subpath, dir, sync_op, frmap_dir_iter, empty_rules, 0, allocator);
            },
            0b01 => {
                //  TODO: pull dir recursively
            },
            0b10 => try self.pipeDir(dir.?),
            0b11 => return SyncFileError.IllegalCombination,
        }
    }
}

pub fn syncFileApplyRules(
    self: *FileReader,
    subpath: []const u8,
    file: ?File,
    sync_op: SyncOp,
    file_record: ?*const FileRecordMap.FileRecord,
    itree_map: IncludeTree,
    level: usize,
) SyncFileError!void {
    if (if (itree_map.flat_tree.map.get(subpath)) |f| !IncludeTree.levelIsIgnore(f.level) else IncludeTree.levelIsIgnore(level))
        try self.syncFile(file, sync_op, file_record);
}

/// if not null, `dir` must be open with iterate flag
pub fn syncDirApplyRules(
    self: *FileReader,
    subpath: []const u8,
    dir: ?Dir,
    sync_op: SyncOp,
    frmap_dir_iter: FileRecordMap.DirIterator,
    itree_map: IncludeTree,
    level: usize,
    allocator: std.mem.Allocator,
) SyncDirError!void {
    var dir_list: std.ArrayListUnmanaged(FileRecordMap.EntryT) = .empty;
    defer dir_list.deinit(allocator);

    var dir_list_iter = struct {
        dir_list: *const @TypeOf(dir_list),
        index: usize = 0,

        pub fn next(dl: *@This()) ?FileRecordMap.EntryT {
            return if (dl.index < dl.dir_list.items.len) blk: {
                const entry = dl.dir_list.items[dl.index];
                dl.index += 1;
                break :blk entry;
            } else null;
        }
    }{ .dir_list = &dir_list };

    if (dir) |d| {
        var dir_iter = d.iterate();
        while (dir_iter.next() catch |err| {
            log.err(iter_dir_error_notice, .{err});
            return PipeDirError.IncompleteTransaction;
        }) |entry| {
            switch (entry.kind) {
                .directory, .file => |k| {
                    const full_path = try std.mem.join(allocator, "/", if (subpath.len == 0) &.{entry.name} else &.{ subpath, entry.name });

                    try dir_list.append(allocator, .{
                        .full_path = full_path,
                        .kind = switch (k) {
                            .file => .{ .file = {} },
                            .directory => .{ .directory = undefined },
                            else => unreachable,
                        },
                    });
                },
                else => continue,
            }
        }
    }
    defer for (dir_list.items) |item| {
        allocator.free(item.full_path);
    };

    std.mem.sortUnstable(FileRecordMap.EntryT, dir_list.items, {}, struct {
        pub fn lessThan(_: void, lhs: FileRecordMap.EntryT, rhs: FileRecordMap.EntryT) bool {
            return std.mem.lessThan(u8, lhs.getEntryName(), rhs.getEntryName());
        }
    }.lessThan);

    var frmap_dir_iter_mut = frmap_dir_iter;

    var fsys_entry: ?FileRecordMap.EntryT = dir_list_iter.next();
    var frmap_entry: ?FileRecordMap.EntryT = frmap_dir_iter_mut.next();

    var has_error = false;

    while (fsys_entry != null or frmap_entry != null) {
        var is_dir = false;
        var full_path: []const u8 = undefined;
        var fsys_e: ?FileRecordMap.EntryT = null;
        var frmap_e: ?FileRecordMap.EntryT = null;

        const order = if (fsys_entry != null and frmap_entry != null) std.mem.order(u8, fsys_entry.?.full_path, frmap_entry.?.full_path) else null;

        if (if (order) |o| o == .eq or o == .lt else fsys_entry != null) {
            is_dir = fsys_entry.?.kind == .directory;
            full_path = fsys_entry.?.full_path;
            fsys_e = fsys_entry;
            fsys_entry = dir_list_iter.next();
        }

        if (if (order) |o| (o == .eq or o == .gt) else frmap_entry != null) {
            is_dir = frmap_entry.?.kind == .directory;
            full_path = frmap_entry.?.full_path;
            frmap_e = frmap_entry;
            frmap_entry = frmap_dir_iter_mut.next();
        }

        if (is_dir) {
            const path_info = itree_map.sortedMapGetPathInfo(full_path, level);

            if (!path_info.ignore or path_info.nested_rules) {
                var child_dir: ?Dir = if (fsys_e) |d| dir.?.openDir(d.getEntryName(), .{ .iterate = true }) catch |err| {
                    log.err(open_dir_error_notice, .{ full_path, err });
                    continue;
                } else null;
                defer if (child_dir) |*d| d.close();

                const child_dir_iter: FileRecordMap.DirIterator = if (frmap_e) |fre| fre.kind.directory else .empty;

                const res = if (path_info.nested_rules)
                    self.syncDirApplyRules(full_path, child_dir, sync_op, child_dir_iter, itree_map, if (path_info.is_map_entry) level + 1 else level, allocator)
                else
                    self.syncDir(full_path, child_dir, sync_op, child_dir_iter, allocator);

                res catch |err| switch (err) {
                    SyncDirError.IncompleteTransaction => {
                        log.warn(dir_transaction_error_notice, .{full_path});
                        has_error = true;
                        continue;
                    },
                    SyncDirError.OutOfMemory => |e| return e,
                    else => continue,
                };
            }
        } else {
            const file: ?File = if (fsys_e) |f| dir.?.openFile(f.getEntryName(), .{}) catch |err| {
                log.err(open_file_error_notice, .{ full_path, err });
                has_error = true;
                continue;
            } else null;
            defer if (file) |f| f.close();

            self.syncFileApplyRules(full_path, file, sync_op, frmap_dir_iter.sorted_map.file_records.getPtr(.borrowed(full_path)), itree_map, level) catch |err| switch (err) {
                SyncFileError.IllegalCombination, SyncFileError.NoOp, SyncFileError.NoPushDeletedPullNew, SyncFileError.NoPushNewPullDeleted => continue,
                SyncFileError.OutOfMemory => |e| return e,
                else => {
                    log.err(sync_file_error_notice, .{ full_path, err });
                    has_error = true;
                    continue;
                },
            };
        }
    }

    if (has_error)
        return SyncDirError.IncompleteTransaction;
}
