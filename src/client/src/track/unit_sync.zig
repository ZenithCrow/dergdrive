const std = @import("std");
const Dir = std.Io.Dir;
const File = std.Io.File;

const dergdrive = @import("dergdrive");
const FileReader = dergdrive.client.rxtx.FileReader;

const FileRecordMap = @import("FileRecordMap.zig");
const IncludeTree = @import("IncludeTree.zig");
const SyncOp = @import("SyncOp.zig");

pub const FlagError = error{
    NoOp,
    NoPushDeletedPullNew,
    IllegalCombination,
    NoPushNewPullDeleted,
};
pub const SyncFileError = FlagError || std.mem.Allocator.Error || FileReader.PipeFileError || File.StatError;
pub const PipeDirError = error{IncompleteTransaction} || std.mem.Allocator.Error;
pub const SyncDirError = PipeDirError || FlagError || std.mem.Allocator.Error;

const log = std.log.scoped(.@"client/track/unit_sync");

pub const iter_dir_error_notice = "Couldn't properly iterate directory due to error: {t}.";
pub const open_dir_error_notice = "Couldn't open directory \"{s}\" due to error {t}.";
pub const dir_transaction_error_notice = "Transaction of directory \"{s}\" is only partially successful.";

pub const SyncUnitCtx = struct {
    f_reader: *FileReader,
    allocator: std.mem.Allocator,
    io: std.Io,
};

pub fn syncFile(
    ctx: SyncUnitCtx,
    path: []const u8,
    file: ?File,
    sync_op: SyncOp,
    file_record: ?FileRecordMap.FileRecord,
) SyncFileError!void {
    if (file == null) {
        if (file_record) |fr| {
            _ = fr;
            switch (@as(u2, @intFromBool(sync_op.push.deleted)) << 1 | @as(u2, @intFromBool(sync_op.pull.new))) {
                0b00 => return SyncFileError.NoPushDeletedPullNew,
                0b01 => {
                    log.info("pull file: {s}", .{path});
                    //  TODO: pull file
                },
                0b10 => {
                    log.info("delete server file: {s}", .{path});
                    //  TODO: delete file on server
                },
                0b11 => return SyncFileError.IllegalCombination,
            }
        } else return SyncFileError.NoOp;
    } else if (file_record == null) {
        switch (@as(u2, @intFromBool(sync_op.push.new)) << 1 | @as(u2, @intFromBool(sync_op.pull.deleted))) {
            0b00 => return SyncFileError.NoPushNewPullDeleted,
            0b01 => {
                log.info("delete local file: {s}", .{path});
                //  TODO: delele file locally
            },
            0b10 => {
                log.info("push file: {s}", .{path});
                //try self.pipeFile(file.?, try self.req_stor.newPushFileNew());
            },
            0b11 => return SyncFileError.IllegalCombination,
        }
    } else {
        switch (@as(u2, @intFromBool(sync_op.push.force)) << 1 | @as(u2, @intFromBool(sync_op.pull.force))) {
            0b00 => {
                const stat = try file.?.stat(ctx.io);
                if (@as(i128, @intCast(stat.mtime.nanoseconds)) > file_record.?.tstamp.mod_time) {
                    log.info("push file: {s}", .{path});
                    //try self.pipeFile(file.?, try self.req_stor.newPushFileNew());
                } else if (@as(i128, @intCast(stat.mtime.nanoseconds)) < file_record.?.tstamp.mod_time) {
                    log.info("pull file: {s}", .{path});
                    //  TODO: pull file
                }
            },
            0b01 => {
                log.info("pull file: {s}", .{path});
                //  TODO: pull file
            },
            0b10 => {
                log.info("push file: {s}", .{path});
                //try self.pipeFile(file.?, try self.req_stor.newPushFileNew());
            },
            0b11 => return SyncFileError.IllegalCombination,
        }
    }
}

/// similar to `syncDirApplyRules` but always pushes, skipping the process of deciding which operation to perform
/// if not null, `dir` must be opened with iterate flag
pub fn pipeDir(ctx: SyncUnitCtx, path: []const u8, dir: Dir, frmap_dir_iter: FileRecordMap.DirIterator) PipeDirError!void {
    var has_error: bool = false;
    var dir_iter = dir.iterate();
    while (dir_iter.next(ctx.io) catch |err| {
        log.err(iter_dir_error_notice, .{err});
        return PipeDirError.IncompleteTransaction;
    }) |entry| {
        switch (entry.kind) {
            .file, .directory => |k| {
                const full_path = try std.mem.join(ctx.allocator, "/", if (path.len == 0) &.{entry.name} else &.{ path, entry.name });
                defer ctx.allocator.free(full_path);

                switch (k) {
                    .file => {
                        const file = dir.openFile(ctx.io, entry.name, .{}) catch |err| {
                            log.err(FileReader.open_file_error_notice, .{ full_path, err });
                            has_error = true;
                            continue;
                        };
                        defer file.close(ctx.io);

                        log.info("push file: {s}", .{full_path});
                        const pipe_info: FileReader.PipeInfo = .{
                            .path = full_path,
                            .dests = if (frmap_dir_iter.sorted_map.file_records.get(.borrowed(full_path))) |r| r.chunks else &.{},
                        };

                        ctx.f_reader.pipeFile(file, pipe_info, ctx.allocator, ctx.io) catch |err| {
                            log.err(FileReader.pipe_file_error_notice, .{ full_path, err });
                            has_error = true;
                            continue;
                        };
                    },
                    .directory => {
                        var subdir = dir.openDir(ctx.io, entry.name, .{ .iterate = true }) catch |err| {
                            log.err(open_dir_error_notice, .{ full_path, err });
                            has_error = true;
                            continue;
                        };
                        defer subdir.close(ctx.io);

                        pipeDir(ctx, full_path, subdir, frmap_dir_iter) catch |err| switch (err) {
                            PipeDirError.OutOfMemory => return err,
                            PipeDirError.IncompleteTransaction => {
                                log.warn(dir_transaction_error_notice, .{full_path});
                                has_error = true;
                                continue;
                            },
                        };
                    },
                    else => unreachable,
                }
            },
            else => continue,
        }
    }

    if (has_error)
        return PipeDirError.IncompleteTransaction;
}

/// if not null, `dir` must be open with iterate flag
pub fn syncDir(
    ctx: SyncUnitCtx,
    path: []const u8,
    dir: ?Dir,
    sync_op: SyncOp,
    frmap_dir_iter: FileRecordMap.DirIterator,
) SyncDirError!void {
    if (dir == null) {
        if (frmap_dir_iter.dir_range.@"0" < frmap_dir_iter.dir_range.@"1") {
            switch (@as(u2, @intFromBool(sync_op.push.deleted)) << 1 | @as(u2, @intFromBool(sync_op.pull.new))) {
                0b00 => return SyncDirError.NoPushDeletedPullNew,
                0b01 => {
                    log.info("pull dir: {s}", .{path});
                    //  TODO: pull dir recursively
                },
                0b10 => {
                    log.info("delete server dir: {s}", .{path});
                    //  TODO: delete dir recursively on server
                },
                0b11 => return SyncDirError.IllegalCombination,
            }
        } else return SyncDirError.NoOp;
    } else if (frmap_dir_iter.dir_range.@"0" == frmap_dir_iter.dir_range.@"1") {
        switch (@as(u2, @intFromBool(sync_op.push.new)) << 1 | @as(u2, @intFromBool(sync_op.pull.deleted))) {
            0b00 => return SyncDirError.NoPushNewPullDeleted,
            0b01 => {
                log.info("delete local dir: {s}", .{path});
                //  TODO: delele dir recursively locally
            },
            0b10 => try pipeDir(ctx, path, dir.?, frmap_dir_iter),
            0b11 => return SyncDirError.IllegalCombination,
        }
    } else {
        switch (@as(u2, @intFromBool(sync_op.push.force)) << 1 | @as(u2, @intFromBool(sync_op.pull.force))) {
            0b00 => {
                const empty_rules: IncludeTree = .{
                    .allocator = undefined,
                    .flat_tree = .{ .map = .empty },
                    .root_dir = undefined,
                    .rules = undefined,
                    .io = undefined,
                };

                try syncDirApplyRules(ctx, path, dir, sync_op, frmap_dir_iter, empty_rules, 0);
            },
            0b01 => {
                log.info("pull dir: {s}", .{path});
                //  TODO: pull dir recursively
            },
            0b10 => try pipeDir(ctx, path, dir.?, frmap_dir_iter),
            0b11 => return SyncDirError.IllegalCombination,
        }
    }
}

pub fn syncFileApplyRules(
    ctx: SyncUnitCtx,
    path: []const u8,
    file: ?File,
    sync_op: SyncOp,
    file_record: ?FileRecordMap.FileRecord,
    itree_map: IncludeTree,
    level: usize,
) SyncFileError!void {
    if (if (itree_map.flat_tree.map.get(path)) |f| !IncludeTree.levelIsIgnore(f.level) else IncludeTree.levelIsIgnore(level)) {
        try syncFile(ctx, path, file, sync_op, file_record);
    } else {
        log.debug("ignoring: {s}", .{path});
    }
}

/// if not null, `dir` must be open with iterate flag
pub fn syncDirApplyRules(
    ctx: SyncUnitCtx,
    path: []const u8,
    dir: ?Dir,
    sync_op: SyncOp,
    frmap_dir_iter: FileRecordMap.DirIterator,
    itree_map: IncludeTree,
    level: usize,
) SyncDirError!void {
    var dir_list: std.ArrayListUnmanaged(FileRecordMap.EntryT) = .empty;
    defer dir_list.deinit(ctx.allocator);

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
        while (dir_iter.next(ctx.io) catch |err| {
            log.err(iter_dir_error_notice, .{err});
            return PipeDirError.IncompleteTransaction;
        }) |entry| {
            switch (entry.kind) {
                .directory, .file => |k| {
                    const full_path = try std.mem.join(ctx.allocator, "/", if (path.len == 0) &.{entry.name} else &.{ path, entry.name });

                    try dir_list.append(ctx.allocator, .{
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
        ctx.allocator.free(item.full_path);
    };

    std.mem.sortUnstable(FileRecordMap.EntryT, dir_list.items, {}, struct {
        pub fn lessThan(_: void, lhs: FileRecordMap.EntryT, rhs: FileRecordMap.EntryT) bool {
            return std.mem.lessThan(u8, lhs.getEntryName(), rhs.getEntryName());
        }
    }.lessThan);

    std.debug.print("\ndir_list_iter entries:\n", .{});
    var dliter = dir_list_iter;
    while (dliter.next()) |entry| {
        std.debug.print("{f}\n", .{entry});
    }

    std.debug.print("\nfrmap_dir_iter entries:\n", .{});
    var fmiter = frmap_dir_iter;
    while (fmiter.next()) |entry| {
        std.debug.print("{f}\n", .{entry});
    }

    std.debug.print("\n", .{});

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

        log.debug("fsys_e: {?f}", .{fsys_e});
        log.debug("frmap_e: {?f}", .{frmap_e});

        if (is_dir) {
            const path_info = itree_map.sortedMapGetPathInfo(full_path, level);
            log.debug("path_info: nested_rules: {any}; {s}", .{ path_info.nested_rules, if (path_info.ignore) "ignore" else "include" });

            if (!path_info.ignore or path_info.nested_rules) {
                var child_dir: ?Dir = if (fsys_e) |d| dir.?.openDir(ctx.io, d.getEntryName(), .{ .iterate = true }) catch |err| {
                    log.err(open_dir_error_notice, .{ full_path, err });
                    continue;
                } else null;
                defer if (child_dir) |*d| d.close(ctx.io);

                const child_dir_iter: FileRecordMap.DirIterator = if (frmap_e) |fre| fre.kind.directory else .empty;

                const res = if (path_info.nested_rules) blk: {
                    log.debug("syncDirApplyRules", .{});
                    break :blk syncDirApplyRules(ctx, full_path, child_dir, sync_op, child_dir_iter, itree_map, if (path_info.is_map_entry) level + 1 else level);
                } else blk: {
                    log.debug("syncDir", .{});
                    break :blk syncDir(ctx, full_path, child_dir, sync_op, child_dir_iter);
                };

                res catch |err| switch (err) {
                    SyncDirError.IncompleteTransaction => {
                        log.warn(dir_transaction_error_notice, .{full_path});
                        has_error = true;
                        continue;
                    },
                    SyncDirError.OutOfMemory => |e| return e,
                    else => continue,
                };
            } else log.debug("ignoring: {s}", .{full_path});
        } else {
            const file: ?File = if (fsys_e) |f| dir.?.openFile(ctx.io, f.getEntryName(), .{}) catch |err| {
                log.err(FileReader.open_file_error_notice, .{ full_path, err });
                has_error = true;
                continue;
            } else null;
            defer if (file) |f| f.close(ctx.io);

            log.debug("syncFileApplyRules", .{});

            syncFileApplyRules(ctx, full_path, file, sync_op, frmap_dir_iter.sorted_map.file_records.get(.borrowed(full_path)), itree_map, level) catch |err| switch (err) {
                SyncFileError.IllegalCombination, SyncFileError.NoOp, SyncFileError.NoPushDeletedPullNew, SyncFileError.NoPushNewPullDeleted => continue,
                SyncFileError.OutOfMemory => |e| return e,
                else => {
                    log.err(FileReader.sync_file_error_notice, .{ full_path, err });
                    has_error = true;
                    continue;
                },
            };
        }
    }

    if (has_error)
        return SyncDirError.IncompleteTransaction;
}

pub inline fn syncRootDirApplyRules(
    ctx: SyncUnitCtx,
    dir: Dir,
    sync_op: SyncOp,
    frmap: FileRecordMap,
    itree_map: IncludeTree,
) SyncDirError!void {
    try syncDirApplyRules(
        ctx,
        "",
        dir,
        sync_op,
        .{
            .dir_range = .{
                0,
                frmap.file_records.count(),
            },
            .parent_path = "",
            .sorted_map = &frmap,
        },
        itree_map,
        0,
    );
}
