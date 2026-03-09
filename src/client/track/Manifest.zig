const std = @import("std");

const crypt = @import("dergdrive").crypt;

const IncludeTree = @import("IncludeTree.zig");

const Manifest = @This();

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

const capacity_exp = 64;

mfest_file: []const u8,
sync_tstamp: Timestamp,
file_records: std.StringHashMap(FileRecord),
oride_pfixes: std.AutoHashMap(u32, []const u8),
allocator: std.mem.Allocator,

// TODO pass config location so that this module can load the prefix config
pub fn init(allocator: std.mem.Allocator) Manifest {
    return .{
        // TODO mfest_file is not available at the time of init, maybe make it nullable?
        .mfest_file = undefined,
        .sync_tstamp = undefined,
        .file_records = .init(allocator),
        .oride_pfixes = .init(allocator),
        .allocator = allocator,
    };
}

pub fn getSyncTimestamp(self: Manifest) Timestamp {
    return .{
        .mod_time = std.mem.bytesToValue(i128, self.mfest_file[0..@sizeOf(i128)]),
        .mod_dev_id = std.mem.bytesToValue(u32, self.mfest_file[@sizeOf(i128)..@sizeOf(Timestamp)]),
    };
}

fn getOverridePrefixesIterator(self: Manifest) OridePrefixIterator {
    const start_buf = self.mfest_file[@sizeOf(Timestamp)..];
    return .{
        .elem_len = std.mem.bytesToValue(u32, start_buf[0..@sizeOf(u32)]),
        .section_start = start_buf[@sizeOf(u32)..],
    };
}

fn loadOverridePrefixes(self: *Manifest) std.mem.Allocator.Error!OridePrefix {
    var iter = self.getOverridePrefixesIterator();
    while (iter.next()) |oride_pfix| {
        try self.oride_pfixes.put(oride_pfix.id, oride_pfix.prefix);
    }

    return iter;
}

fn getFileRecordIterator(oride_pfix_iter: OridePrefixIterator) FileRecordIterator {
    var local_iter = oride_pfix_iter;
    while (local_iter.next() != null) {}

    const section_len_start: usize = @intCast(local_iter.byte_idx);

    return .{
        .elem_len = std.mem.bytesToValue(u64, local_iter.section_start[section_len_start .. section_len_start + @sizeOf(u64)]),
        .section_start = local_iter.section_start[section_len_start + @sizeOf(u64)],
    };
}
