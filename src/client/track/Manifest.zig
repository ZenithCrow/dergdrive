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
//  TODO: let file_records key type know if the string was allocated in place
file_records: std.StringHashMap(FileRecord),
local_pfixes: std.AutoHashMap(u32, []const u8),
oride_pfixes: std.AutoHashMap(u32, []const u8),
allocator: std.mem.Allocator,

//  TODO: pass config location so that this module can load the prefix config
pub fn init(allocator: std.mem.Allocator) Manifest {
    return .{
        //  TODO: mfest_file is not available at the time of init, maybe make it nullable?
        .mfest_file = undefined,
        .sync_tstamp = undefined,
        .file_records = .init(allocator),
        .local_pfixes = .init(allocator),
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
        const local_fp = blk: {
            if (self.local_pfixes.get(file_record.pfix_id)) |local_pfix| {
                if (self.oride_pfixes.get(file_record.pfix_id)) |oride_pfix| {
                    if (std.mem.startsWith(u8, file_record.path, oride_pfix) and file_record.path.len > oride_pfix.len) {
                        const repl_buf = try self.allocator.alloc(u8, local_pfix + file_record.path.len - oride_pfix);

                        std.mem.copyForwards(u8, repl_buf[0..local_pfix.len], local_pfix);
                        std.mem.copyForwards(u8, repl_buf[local_pfix.len..], file_record.path[oride_pfix.len..]);

                        break :blk repl_buf;
                    }

                    //  TODO: warn about overridable prefix not being a prefix of the file path
                } else if (file_record.pfix_id != 0) {
                    //  TODO: warn about non-existent overridable prefix
                }
            }

            //  TODO: don't dupe here if the key structure knows which keys are owned
            break :blk try self.allocator.dupe(u8, file_record.path);
        };

        const res = try self.file_records.getOrPut(local_fp);
        if (res.found_existing) {
            //  TODO: warn about overriding an existing file record
        }

        res.value_ptr.* = file_record;
    }
}
