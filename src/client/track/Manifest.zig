const std = @import("std");

const Conf = @import("dergdrive").conf.Conf;
const crypt = @import("dergdrive").crypt;

const IncludeTree = @import("IncludeTree.zig");

const StoreLocalPrefixOverridesError = Conf.OpenOrCreateConfFileError || std.fs.File.WriteError;
const Manifest = @This();

const log = std.log.scoped(.@"client/track/Manifest");

const local_prefix_disclaimer: []const u8 = @embedFile("local-prefix-notice.txt");

const LoadLocalPrefixOverridesError = error{CannotParse} || Conf.GetConfError || std.mem.Allocator.Error;
const OridePrefixIterator = struct {
    section_start: []const u8,
    byte_idx: usize = 0,
    elem_idx: u32 = 0,
    elem_len: u32,

    pub fn next(self: *@This()) ?OridePrefix {
        if (self.byte_idx >= self.section_start.len or self.elem_idx >= self.elem_len)
            return null;

        const prefix = std.mem.span(self.section_start.ptr + self.byte_idx);
        const id_start = @as(usize, @intCast(self.byte_idx)) + prefix.len;

        const oride_pfix: OridePrefix = .{
            .prefix = prefix,
            .id = std.mem.bytesToValue(u32, self.section_start[id_start .. id_start + @sizeOf(u32)]),
        };

        self.byte_idx += prefix.len + @sizeOf(u32);
        self.elem_idx += 1;

        return oride_pfix;
    }
};

const FileRecordIterator = struct {
    section_start: []const u8,
    byte_idx: usize = 0,
    elem_idx: u64 = 0,
    elem_len: u64,

    pub fn next(self: *@This()) ?FileRecord {
        if (self.byte_idx >= self.section_start.len or self.elem_idx >= self.elem_len)
            return null;

        const path = std.mem.span(self.section_start.ptr + self.byte_idx);
        const fixed_data_start = @as(usize, @intCast(self.byte_idx)) + path.len;

        const file_record: FileRecord = .{
            .path = path,
            .tstamp = .{
                .mod_time = std.mem.bytesToValue(i128, self.section_start[fixed_data_start .. fixed_data_start + @sizeOf(i128)]),
                .mod_dev_id = std.mem.bytesToValue(u32, self.section_start[fixed_data_start + @sizeOf(i128) .. fixed_data_start + @sizeOf(i128) + @sizeOf(u32)]),
            },
            .pfix_id = std.mem.bytesToValue(u32, self.section_start[fixed_data_start + @sizeOf(i128) + @sizeOf(u32) .. fixed_data_start + @sizeOf(i128) + 2 * @sizeOf(u32)]),
            .blk_idx = std.mem.bytesToValue(u32, self.section_start[fixed_data_start + @sizeOf(i128) + 2 * @sizeOf(u32) .. fixed_data_start + @sizeOf(i128) + 3 * @sizeOf(u32)]),
            .offset = std.mem.bytesToValue(u32, self.section_start[fixed_data_start + @sizeOf(i128) + 3 * @sizeOf(u32) .. fixed_data_start + @sizeOf(i128) + 4 * @sizeOf(u32)]),
            .length = std.mem.bytesToValue(u64, self.section_start[fixed_data_start + @sizeOf(i128) + 4 * @sizeOf(u32) .. fixed_data_start + @sizeOf(i128) + 4 * @sizeOf(u32) + @sizeOf(u64)]),
        };

        self.byte_idx += path.len + @sizeOf(Timestamp) + 3 * @sizeOf(u32) + @sizeOf(u64);
        self.elem_idx += 1;

        return file_record;
    }
};

const Timestamp = struct {
    mod_time: i128,
    mod_dev_id: u32,
};

const OridePrefix = struct {
    prefix: []const u8,
    id: u32,
};

const FileRecord = struct {
    path: []const u8,
    tstamp: Timestamp,
    pfix_id: u32,
    blk_idx: u32,
    offset: u32,
    length: u64,

    pub fn format(self: FileRecord, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.path);
        try writer.writeAll(std.mem.asBytes(&self.tstamp.mod_time));
        try writer.writeAll(std.mem.asBytes(&self.tstamp.mod_dev_id));
        try writer.writeAll(std.mem.asBytes(&self.pfix_id));
        try writer.writeAll(std.mem.asBytes(&self.blk_idx));
        try writer.writeAll(std.mem.asBytes(&self.offset));
        try writer.writeAll(std.mem.asBytes(&self.length));
    }
};

const FileRecordKey = struct {
    key: []const u8,
    owned: bool,
};

const FileRecordContext = struct {
    pub fn hash(_: @This(), c: FileRecordKey) u32 {
        var key = c.key;

        var h: std.hash.Fnv1a_32 = .init();

        while (key.len >= 64) : (key = key[64..]) {
            h.update(key[0..64]);
        }

        if (key.len > 0)
            h.update(key);

        return h.final();
    }

    pub fn eql(_: @This(), x: FileRecordKey, y: FileRecordKey, _: usize) bool {
        return std.mem.eql(u8, x.key, y.key);
    }
};

conf: Conf,
// owned slice
mfest_file: ?[]const u8 = null,
is_local: bool = true,
sync_tstamp: ?Timestamp = null,
file_records: std.ArrayHashMap(FileRecordKey, FileRecord, FileRecordContext, true),
local_pfixes: std.AutoArrayHashMap(u32, []const u8),
oride_pfixes: std.AutoArrayHashMap(u32, []const u8),
allocator: std.mem.Allocator,

pub fn init(conf: Conf, allocator: std.mem.Allocator) Manifest {
    return .{
        .conf = conf,
        .file_records = .init(allocator),
        .local_pfixes = .init(allocator),
        .oride_pfixes = .init(allocator),
        .allocator = allocator,
    };
}

pub fn deinit(self: *Manifest) void {
    if (self.mfest_file) |mfest| {
        self.allocator.free(mfest);
        self.mfest_file = null;
    }

    self.sync_tstamp = null;

    for (self.file_records.keys()) |key| {
        if (key.owned)
            self.allocator.free(key.key);
    }
    self.file_records.deinit();

    for (self.local_pfixes.values()) |value| {
        self.allocator.free(value);
    }
    self.local_pfixes.deinit();

    self.oride_pfixes.deinit();
}

pub fn getSyncTimestamp(self: Manifest) ?Timestamp {
    return if (self.mfest_file) |mfest| .{
        .mod_time = std.mem.bytesToValue(i128, mfest[0..@sizeOf(i128)]),
        .mod_dev_id = std.mem.bytesToValue(u32, mfest[@sizeOf(i128)..@sizeOf(Timestamp)]),
    } else null;
}

pub fn loadCachedManifest(self: *Manifest) void {
    self.mfest_file = self.conf.getConf(self.conf.mfest_cache, self.allocator) catch |err| switch (err) {
        Conf.GetConfError.FileNotFound => null,
        else => {
            self.mfest_file = null;
            log.warn("Couldn't open cached manifest file due to error: {s}.'", .{@errorName(err)});
            return;
        },
    };
}

pub fn loadLocalPrefixOverrides(self: *Manifest) LoadLocalPrefixOverridesError!void {
    const buf = try self.conf.getConf(self.conf.oride_prefixes, self.allocator);
    defer self.allocator.free(buf);

    var iter: Conf.KeyValueIterator = .init(buf);
    while (iter.next()) |kv| {
        const pfix_id = std.fmt.parseInt(u32, kv.key, 16) catch |err| {
            log.err("Couldn't parse prefix id from key \"{s}\" due to error: {s}.", .{ kv.key, @errorName(err) });
            return LoadLocalPrefixOverridesError.CannotParse;
        };

        if (kv.value.len > 0)
            try self.local_pfixes.put(pfix_id, try self.allocator.dupe(u8, kv.value));
    }
}

test "format id to hex" {
    try std.testing.expectFmt("0000001f", "{x:0>8}", .{0x1f});
    try std.testing.expectFmt("0f0f00af", "{x:0>8}", .{0xf0f00af});
}

pub fn storeLocalPrefixOverrides(self: Manifest) StoreLocalPrefixOverridesError!void {
    const file = try self.conf.openOrCreateConfFile(self.conf.oride_prefixes, true, self.allocator);
    var w_buf: [512]u8 = undefined;
    var writer = file.writer(&w_buf);

    writer.interface.print(local_prefix_disclaimer, .{Conf.proj_name}) catch return writer.err.?;

    var iter = self.oride_pfixes.iterator();
    while (iter.next()) |kv| {
        const oride_val = self.local_pfixes.get(kv.key_ptr.*) orelse "";
        writer.interface.print("# {s}\n", .{kv.value_ptr.*}) catch return writer.err.?;
        writer.interface.print("{x:0>8}={s}\n\n", .{ kv.key_ptr.*, oride_val }) catch return writer.err.?;
    }
}

fn getOverridePrefixIterator(self: Manifest) OridePrefixIterator {
    const start_buf = self.mfest_file[@sizeOf(Timestamp)..];
    return .{
        .elem_len = std.mem.bytesToValue(u32, start_buf[0..@sizeOf(u32)]),
        .section_start = start_buf[@sizeOf(u32)..],
    };
}

/// Returns a depleted `OridePrefixIterator` that can be used as a starting point for iterating the file records section.
fn loadOverridablePrefixes(self: *Manifest) std.mem.Allocator.Error!OridePrefixIterator {
    var iter = self.getOverridePrefixIterator();
    while (iter.next()) |oride_pfix| {
        try self.oride_pfixes.put(oride_pfix.id, oride_pfix.prefix);
    }

    return iter;
}

/// Passing a depleted `OridePrefixIterator` helps find the start of the file records section quicker.
fn getFileRecordIterator(self: Manifest, oride_pfix_iter: ?OridePrefixIterator) FileRecordIterator {
    var local_iter = if (oride_pfix_iter != null) oride_pfix_iter.? else self.getOverridePrefixIterator();
    while (local_iter.next() != null) {}

    const section_len_start: usize = @intCast(local_iter.byte_idx);

    return .{
        .elem_len = std.mem.bytesToValue(u64, local_iter.section_start[section_len_start .. section_len_start + @sizeOf(u64)]),
        .section_start = local_iter.section_start[section_len_start + @sizeOf(u64)],
    };
}

/// Passing a depleted `OridePrefixIterator` helps find the start of the file records section quicker.
fn loadFileRecords(self: *Manifest, oride_pfix_iter: ?OridePrefixIterator) std.mem.Allocator.Error!void {
    var iter = self.getFileRecordIterator(oride_pfix_iter);
    while (iter.next()) |file_record| {
        const local_fp: FileRecordKey = blk: {
            if (self.local_pfixes.get(file_record.pfix_id)) |local_pfix| {
                if (self.oride_pfixes.get(file_record.pfix_id)) |oride_pfix| {
                    if (std.mem.startsWith(u8, file_record.path, oride_pfix) and file_record.path.len > oride_pfix.len) {
                        const repl_buf = try self.allocator.alloc(u8, local_pfix + file_record.path.len - oride_pfix);

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

        const res = try self.file_records.getOrPut(local_fp);
        if (res.found_existing) {
            log.warn("Duplicate file record \"{s}\". Overwriting existing file record.", .{file_record.path});
        }

        res.value_ptr.* = file_record;
    }
}
