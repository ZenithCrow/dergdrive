const std = @import("std");

const dergdrive = @import("dergdrive");
const Conf = dergdrive.conf.Conf;
const crypt = dergdrive.crypt;
const slc = dergdrive.util.slc;

const FileRecordMap = @import("FileRecordMap.zig");

const StoreLocalPrefixOverridesError = Conf.OpenOrCreateConfFileError || std.Io.File.Writer.Error;
const Manifest = @This();

const log = std.log.scoped(.@"client/track/Manifest");

const local_prefix_disclaimer: []const u8 = @embedFile("local-prefix-notice.txt");

const LoadLocalPrefixOverridesError = Conf.GetConfError || std.mem.Allocator.Error;
const GetSyncTimestampFromCachedManifestError = Conf.OpenOrCreateConfFileError || std.Io.File.Reader.Error || LoadFromManifestFileError;
const LoadFromManifestFileError = error{ NotLoaded, Illformed };
const LoadManifestError = LoadFromManifestFileError || std.mem.Allocator.Error;
const StoreManifestError = LoadFromManifestFileError || std.Io.Writer.Error;

const OridePrefixIterator = struct {
    section_start: []const u8,
    byte_idx: usize = 0,
    elem_idx: u32 = 0,
    elem_len: u32,

    pub fn next(self: *@This()) ?OridePrefix {
        if (self.byte_idx >= self.section_start.len or self.elem_idx >= self.elem_len)
            return null;

        const prefix = std.mem.span(@as([*:0]const u8, @ptrCast(self.section_start.ptr)) + self.byte_idx);
        const id_start = self.byte_idx + prefix.len + 1;

        const oride_pfix: OridePrefix = .{
            .prefix = prefix,
            .id = std.mem.readInt(u32, self.section_start[id_start .. id_start + @sizeOf(u32)][0..@sizeOf(u32)], .little),
        };

        self.byte_idx += prefix.len + 1 + @sizeOf(u32);
        self.elem_idx += 1;

        return oride_pfix;
    }
};

const FileRecordIterator = struct {
    section_start: []const u8,
    byte_idx: usize = 0,
    elem_idx: u64 = 0,
    elem_len: u64,

    pub fn next(self: *@This(), allocator: std.mem.Allocator) std.mem.Allocator.Error!?FileRecordMap.FileRecord {
        if (self.byte_idx >= self.section_start.len or self.elem_idx >= self.elem_len)
            return null;

        const buf = self.section_start[self.byte_idx..];
        var reader = std.Io.Reader.fixed(buf);

        const path = (reader.takeDelimiter(0) catch unreachable).?;
        const tstamp_mod_time = reader.takeInt(i128, .little) catch unreachable;
        const tstamp_mod_dev_id = reader.takeInt(u32, .little) catch unreachable;
        const pfix_id = reader.takeInt(u32, .little) catch unreachable;
        const num_blks = reader.takeInt(u32, .little) catch unreachable;
        const length = reader.takeInt(u64, .little) catch unreachable;
        const opts = reader.takeStruct(FileRecordMap.FileRecordOptions, .little) catch unreachable;

        const chunks = try allocator.alloc(FileRecordMap.FileChunk, num_blks);
        for (chunks) |*c| {
            const blk_id_len = crypt.NameHashAlgo.digest_length;
            c.blk_id = (reader.take(blk_id_len) catch unreachable)[0..blk_id_len].*;
            c.blk_offset = reader.takeInt(u32, .little) catch unreachable;
            c.length = reader.takeInt(u32, .little) catch unreachable;
        }

        self.byte_idx += reader.seek;
        self.elem_idx += 1;

        return .{
            .path = path,
            .tstamp = .{
                .mod_time = tstamp_mod_time,
                .mod_dev_id = tstamp_mod_dev_id,
            },
            .pfix_id = pfix_id,
            .num_blks = num_blks,
            .length = length,
            .chunks = chunks,
            .opts = opts,
        };
    }
};

pub const Timestamp = struct {
    mod_time: i128,
    mod_dev_id: u32,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeInt(i128, self.mod_time, .little);
        try writer.writeInt(u32, self.mod_dev_id, .little);
    }
};

const OridePrefix = struct {
    prefix: []const u8,
    id: u32,

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll(self.prefix);
        try writer.writeInt(u32, self.id, .little);
    }
};

const UnassignedPrefix = struct {
    key: []const u8,
    val: []const u8,
};

conf: Conf,
mfest_file: ?slc.SliceConstWithOwnerShip(u8) = null,
is_local: bool = true,
sync_tstamp: ?Timestamp = null,
file_record_map: FileRecordMap,
file_record_chunks_alloced: bool = false,
local_pfixes: std.array_hash_map.Auto(u32, []const u8),
oride_pfixes: std.array_hash_map.Auto(u32, []const u8),
unassigned_pfixes: std.ArrayList(UnassignedPrefix),
allocator: std.mem.Allocator,
io: std.Io,

pub fn init(conf: Conf, allocator: std.mem.Allocator, io: std.Io) Manifest {
    return .{
        .conf = conf,
        .file_record_map = .init(allocator),
        .local_pfixes = .empty,
        .oride_pfixes = .empty,
        .unassigned_pfixes = .empty,
        .allocator = allocator,
        .io = io,
    };
}

pub fn deinit(self: *Manifest) void {
    if (self.mfest_file) |mfest| {
        mfest.deinit();
    }
    self.mfest_file = null;
    self.sync_tstamp = null;

    if (self.file_record_chunks_alloced) {
        for (self.file_record_map.file_records.values()) |val| {
            self.allocator.free(val.chunks);
        }
    }
    self.file_record_map.deinit();

    for (self.local_pfixes.values()) |value| {
        self.allocator.free(value);
    }
    self.local_pfixes.deinit(self.allocator);

    self.oride_pfixes.deinit(self.allocator);

    for (self.unassigned_pfixes.items) |pf| {
        self.allocator.free(pf.key);
        self.allocator.free(pf.val);
    }
    self.unassigned_pfixes.deinit(self.allocator);
}

pub fn getSyncTimestamp(self: Manifest) LoadFromManifestFileError!Timestamp {
    return if (self.mfest_file) |mfest| if (mfest.slc.len < @sizeOf(i128) + @sizeOf(u32)) LoadFromManifestFileError.Illformed else .{
        .mod_time = std.mem.readInt(i128, mfest.slc[0..@sizeOf(i128)], .little),
        .mod_dev_id = std.mem.readInt(u32, mfest.slc[@sizeOf(i128) .. @sizeOf(i128) + @sizeOf(u32)], .little),
    } else LoadFromManifestFileError.NotLoaded;
}

pub fn getSyncTimestampFromCachedManifest(self: Manifest) GetSyncTimestampFromCachedManifestError!?Timestamp {
    const file = self.conf.openOrCreateConfFile(self.conf.mfest_cache, false, self.allocator, self.io) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    var buf: [@sizeOf(i128) + @sizeOf(u32)]u8 = undefined;
    var reader = file.reader(self.io, &.{});
    reader.interface.readSliceAll(&buf) catch |err| switch (err) {
        error.EndOfStream => {},
        error.ReadFailed => return reader.err.?,
    };

    var self_cpy = self;
    self_cpy.mfest_file = .borrowed(&buf);
    return self_cpy.getSyncTimestamp() catch unreachable;
}

pub fn openCachedManifest(self: *Manifest) Conf.GetConfError!void {
    self.mfest_file = .owned(self.conf.getConf(self.conf.mfest_cache, self.allocator, self.io) catch |err| {
        if (self.mfest_file) |mfest| {
            mfest.deinit();
        }

        self.mfest_file = null;

        return switch (err) {
            Conf.GetConfError.FileNotFound => {},
            else => err,
        };
    }, self.allocator);
}

pub fn loadLocalPrefixOverrides(self: *Manifest) LoadLocalPrefixOverridesError!void {
    const buf = try self.conf.getConf(self.conf.oride_prefixes, self.allocator, self.io);
    defer self.allocator.free(buf);

    var iter: Conf.KeyValueIterator = .init(buf);
    while (iter.next()) |kv| {
        if (kv.key.len == 0) {
            log.warn("Couldn't parse prefix from empty key.", .{});
            continue;
        }

        const pfix_id = std.fmt.parseInt(u32, kv.key, 16) catch {
            const pfix = if (kv.key[kv.key.len - 1] == '/') kv.key[0 .. kv.key.len - 1] else kv.key;
            try self.unassigned_pfixes.append(self.allocator, .{ .key = try self.allocator.dupe(u8, pfix), .val = try self.allocator.dupe(u8, kv.value) });
            continue;
        };

        const res = try self.local_pfixes.getOrPut(self.allocator, pfix_id);
        if (res.found_existing) {
            log.warn("Duplicate prefix override id {d}. Overwriting value \"{s}\" with \"{s}\".", .{ res.key_ptr.*, res.value_ptr.*, kv.value });
            self.allocator.free(res.value_ptr.*);
        }

        res.value_ptr.* = try self.allocator.dupe(u8, kv.value);
    }
}

test "format id to hex" {
    try std.testing.expectFmt("0000001f", "{x:0>8}", .{0x1f});
    try std.testing.expectFmt("0f0f00af", "{x:0>8}", .{0xf0f00af});
}

pub fn storeLocalPrefixOverrides(self: Manifest) StoreLocalPrefixOverridesError!void {
    const file = try self.conf.openOrCreateConfFile(self.conf.oride_prefixes, true, self.allocator, self.io);
    var w_buf: [512]u8 = undefined;
    var writer = file.writer(self.io, &w_buf);

    writer.interface.print(local_prefix_disclaimer, .{Conf.proj_name}) catch return writer.err.?;

    var iter = self.oride_pfixes.iterator();
    while (iter.next()) |kv| {
        const oride_val = self.local_pfixes.get(kv.key_ptr.*) orelse "";
        writer.interface.print("# {s}\n", .{kv.value_ptr.*}) catch return writer.err.?;
        writer.interface.print("{x:0>8}={s}\n\n", .{ kv.key_ptr.*, oride_val }) catch return writer.err.?;
    }
}

fn getOverridePrefixIterator(self: Manifest) LoadFromManifestFileError!OridePrefixIterator {
    const mfest = self.mfest_file orelse return LoadFromManifestFileError.NotLoaded;
    if (mfest.slc.len < @sizeOf(i128) + @sizeOf(u32))
        return LoadFromManifestFileError.Illformed;

    const start_buf = mfest.slc[@sizeOf(i128) + @sizeOf(u32) ..];
    return .{
        .elem_len = std.mem.readInt(u32, start_buf[0..@sizeOf(u32)], .little),
        .section_start = start_buf[@sizeOf(u32)..],
    };
}

/// Returns a depleted `OridePrefixIterator` that can be used as a starting point for iterating the file records section.
fn loadOverridablePrefixes(self: *Manifest) (std.mem.Allocator.Error || LoadFromManifestFileError)!OridePrefixIterator {
    var iter = try self.getOverridePrefixIterator();
    while (iter.next()) |oride_pfix| {
        try self.oride_pfixes.put(self.allocator, oride_pfix.id, oride_pfix.prefix);
    }

    return iter;
}

fn storeOverridablePrefixes(self: *Manifest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const count: u32 = @truncate(self.oride_pfixes.count());
    try writer.writeInt(u32, count, .little);

    var iter = self.oride_pfixes.iterator();
    while (iter.next()) |kv| {
        try writer.writeAll(kv.value_ptr.*);
        try writer.writeInt(u8, 0, .little);
        try writer.writeInt(u32, kv.key_ptr.*, .little);
    }
}

/// Passing a depleted `OridePrefixIterator` helps find the start of the file records section quicker.
fn getFileRecordIterator(self: Manifest, oride_pfix_iter: ?OridePrefixIterator) LoadFromManifestFileError!FileRecordIterator {
    var local_iter = if (oride_pfix_iter != null) oride_pfix_iter.? else try self.getOverridePrefixIterator();
    while (local_iter.next() != null) {}

    const section_len_start = local_iter.byte_idx;

    return .{
        .elem_len = std.mem.readInt(u64, local_iter.section_start[section_len_start .. section_len_start + @sizeOf(u64)][0..@sizeOf(u64)], .little),
        .section_start = local_iter.section_start[section_len_start + @sizeOf(u64) ..],
    };
}

/// Passing a depleted `OridePrefixIterator` helps find the start of the file records section quicker.
fn loadFileRecords(self: *Manifest, oride_pfix_iter: ?OridePrefixIterator) (LoadFromManifestFileError || std.mem.Allocator.Error)!void {
    var iter = try self.getFileRecordIterator(oride_pfix_iter);
    self.file_record_chunks_alloced = true;
    while (try iter.next(self.allocator)) |file_record| {
        const local_fp: FileRecordMap.FileRecordKey = blk: {
            if (self.local_pfixes.get(file_record.pfix_id)) |local_pfix| {
                if (self.oride_pfixes.get(file_record.pfix_id)) |oride_pfix| {
                    if (std.mem.startsWith(u8, file_record.path, oride_pfix)) {
                        const repl_buf = try self.allocator.alloc(u8, local_pfix.len + file_record.path.len - oride_pfix.len);

                        std.mem.copyForwards(u8, repl_buf[0..local_pfix.len], local_pfix);
                        std.mem.copyForwards(u8, repl_buf[local_pfix.len..], file_record.path[oride_pfix.len..]);

                        break :blk .{ .key = repl_buf, .owned = true };
                    }

                    log.warn("Prefix \"{s}\" is not applicable to filepath \"{s}\". Using provided filepath instead of the prefix.", .{ oride_pfix, file_record.path });
                } else if (file_record.pfix_id != 0) {
                    log.warn("No such prefix exists with id {d}.", .{file_record.pfix_id});
                }
            }

            break :blk .{ .key = file_record.path, .owned = false };
        };

        const res = try self.file_record_map.file_records.getOrPut(self.allocator, local_fp);
        if (res.found_existing)
            log.warn("Duplicate file record \"{s}\". Overwriting existing file record.", .{file_record.path});

        res.value_ptr.* = file_record;
    }
}

fn storeFileRecords(self: *Manifest, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const count: u64 = @intCast(self.file_record_map.file_records.count());
    try writer.writeInt(u64, count, .little);

    for (self.file_record_map.file_records.values()) |val| {
        try val.format(writer);
    }
}

/// make sure to load local prefix overrides prior to this
pub fn loadManifest(self: *Manifest) LoadManifestError!void {
    self.oride_pfixes.clearRetainingCapacity();
    self.file_record_map.clear();
    self.unassigned_pfixes.clearRetainingCapacity();

    self.sync_tstamp = try self.getSyncTimestamp();
    const oride_pfix_iter = try self.loadOverridablePrefixes();

    var lowest_idx: u32 = 1;
    for (self.unassigned_pfixes.items) |pair| {
        while (self.oride_pfixes.get(lowest_idx) != null) {
            lowest_idx += 1;
        }

        try self.oride_pfixes.putNoClobber(self.allocator, lowest_idx, pair.key);
        const res = try self.local_pfixes.getOrPut(self.allocator, lowest_idx);
        if (res.found_existing)
            log.warn("Duplicate prefix override \"{s}\". Overwriting value \"{s}\" with \"{s}\".", .{ pair.key, res.value_ptr.*, pair.val });

        res.value_ptr.* = pair.val;
    }

    try self.loadFileRecords(oride_pfix_iter);
}

pub fn storeManifest(self: *Manifest, writer: *std.Io.Writer) StoreManifestError!void {
    if (self.sync_tstamp == null)
        return StoreManifestError.NotLoaded;

    try self.sync_tstamp.?.format(writer);
    try self.storeOverridablePrefixes(writer);
    try self.storeFileRecords(writer);
}

test "manifest parsing" {
    const allocator = std.testing.allocator;
    var arena_alloc: std.heap.ArenaAllocator = .init(allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const io = std.testing.io;

    var emap = try std.testing.environ.createMap(arena);
    defer emap.deinit();

    const conf: Conf = .{ .vol = "test_vol", .emap = &emap };
    var manifest: Manifest = .init(conf, allocator, io);
    defer manifest.deinit();

    manifest.sync_tstamp = .{ .mod_dev_id = 5, .mod_time = 0 };
    manifest.mfest_file = .borrowed(&.{});

    try manifest.oride_pfixes.put(allocator, 2, "foo/bar");
    try manifest.oride_pfixes.put(allocator, 1, "override/me");

    try manifest.local_pfixes.put(allocator, 1, try allocator.dupe(u8, "owo/owo"));

    const generic_chunk: FileRecordMap.FileChunk = .{
        .blk_id = "blemblemblemblem".*,
        .blk_offset = 0,
        .length = 1,
    };

    const rec1: FileRecordMap.FileRecord = .{
        .length = 98425,
        .chunks = &.{generic_chunk},
        .num_blks = 1,
        .opts = .{
            .deleted = false,
        },
        .path = "foo/owo",
        .pfix_id = 0,
        .tstamp = .{
            .mod_dev_id = 1,
            .mod_time = 0,
        },
    };

    const rec2: FileRecordMap.FileRecord = .{
        .length = 885822,
        .num_blks = 1,
        .chunks = &.{generic_chunk},
        .opts = .{
            .deleted = false,
        },
        .path = "override/me",
        .pfix_id = 1,
        .tstamp = .{
            .mod_dev_id = 2,
            .mod_time = 0,
        },
    };

    try manifest.file_record_map.put(.borrowed("foo/owo"), rec1);

    try manifest.file_record_map.put(.borrowed("owo/owo"), rec2);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();

    try manifest.storeManifest(&writer.writer);

    manifest.mfest_file = .borrowed(writer.written());
    try manifest.loadManifest();

    try std.testing.expectEqualDeep(rec1, manifest.file_record_map.file_records.get(.borrowed("foo/owo")).?);
    try std.testing.expectEqualDeep(rec2, manifest.file_record_map.file_records.get(.borrowed("owo/owo")).?);
}
