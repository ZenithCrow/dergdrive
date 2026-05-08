const std = @import("std");
const Mutex = std.Io.Mutex;

const dergdrive = @import("dergdrive");
const slc = dergdrive.util.slc;

const Manifest = @import("Manifest.zig");

const FileRecordMap = @This();

const log = std.log.scoped(.@"client/track/FileRecordMap");

pub const FileRecord = struct {
    path: []const u8,
    tstamp: Manifest.Timestamp,
    pfix_id: u32,
    num_blks: u32,
    length: u64,
    chunks: []const FileChunk,
    opts: FileRecordOptions,

    pub fn format(self: FileRecord, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.path);
        try writer.writeInt(u8, 0, .little);

        try self.tstamp.format(writer);
        try writer.writeInt(u32, self.pfix_id, .little);
        try writer.writeInt(u32, self.num_blks, .little);
        try writer.writeInt(u64, self.length, .little);
        try writer.writeStruct(self.opts, .little);

        for (self.chunks) |c| {
            try c.format(writer);
        }
    }
};

pub const FileRecordOptions = packed struct(u8) {
    deleted: bool,
    reserved: u7 = undefined,
};

pub const FileChunk = struct {
    blk_id: [dergdrive.crypt.NameHashAlgo.digest_length]u8,
    blk_offset: u32,
    length: u32,

    pub fn format(self: FileChunk, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(&self.blk_id);
        try writer.writeInt(u32, self.blk_offset, .little);
        try writer.writeInt(u32, self.length, .little);
    }
};

pub const FileRecordKey = struct {
    key: []const u8,
    owned: bool,

    pub fn borrowed(key: []const u8) FileRecordKey {
        return .{
            .key = key,
            .owned = false,
        };
    }
};

const FileRecordContext = struct {
    pub fn hash(_: @This(), c: FileRecordKey) u32 {
        var h: std.hash.Fnv1a_32 = .init();

        h.update(c.key);
        return h.final();
    }

    pub fn eql(_: @This(), x: FileRecordKey, y: FileRecordKey, _: usize) bool {
        return std.mem.eql(u8, x.key, y.key);
    }
};

const FileRecordHashMap = std.ArrayHashMapUnmanaged(FileRecordKey, FileRecord, FileRecordContext, true);

file_records: FileRecordHashMap = .empty,
sorted: bool = false,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) FileRecordMap {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *FileRecordMap) void {
    for (self.file_records.keys()) |key| {
        if (key.owned)
            self.allocator.free(key.key);
    }
    self.file_records.deinit(self.allocator);
}

pub inline fn clear(self: *FileRecordMap) void {
    self.file_records.clearRetainingCapacity();
    self.sorted = false;
}

pub inline fn put(self: *FileRecordMap, key: FileRecordKey, val: FileRecord) std.mem.Allocator.Error!void {
    try self.file_records.put(self.allocator, key, val);
    self.sorted = false;
}

pub fn sort(self: *FileRecordMap) void {
    self.file_records.sort(struct {
        self: *FileRecordHashMap,

        pub fn lessThan(ctx: @This(), a_i: usize, b_i: usize) bool {
            const keys = ctx.self.keys();
            return std.mem.lessThan(u8, keys[a_i].key, keys[b_i].key);
        }
    }{ .self = &self.file_records });

    self.sorted = true;
}

pub fn sortedMapGetDirRangeBounded(self: FileRecordMap, dir_path: []const u8, bounds: struct { usize, usize }) struct { usize, usize } {
    std.debug.assert(self.sorted);

    if (dir_path.len == 0)
        return .{ 0, self.file_records.keys().len };

    const rel_range = std.sort.equalRange(FileRecordKey, self.file_records.keys()[bounds.@"0"..bounds.@"1"], dir_path, struct {
        pub fn compareFn(context: []const u8, item: FileRecordKey) std.math.Order {
            if (std.mem.startsWith(u8, item.key, context))
                return std.math.Order.eq;

            return std.mem.order(u8, context, item.key);
        }
    }.compareFn);

    return .{
        rel_range.@"0" + bounds.@"0",
        rel_range.@"1" + bounds.@"0",
    };
}

pub inline fn sortedMapGetDirRange(self: FileRecordMap, dir_path: []const u8) struct { usize, usize } {
    return self.sortedMapGetDirRangeBounded(dir_path, .{ 0, self.file_records.keys().len });
}

pub fn sortedMapGetDirBounded(self: FileRecordMap, dir_path: []const u8, bounds: struct { usize, usize }) []FileRecord {
    const range = self.sortedMapGetDirRangeBounded(dir_path, bounds);
    return self.file_records.values()[range.@"0"..range.@"1"];
}

pub fn sortedMapGetDir(self: FileRecordMap, dir_path: []const u8) []FileRecord {
    const range = self.sortedMapGetDirRange(dir_path);
    return self.file_records.values()[range.@"0"..range.@"1"];
}

pub const EntryT = struct {
    full_path: []const u8,
    kind: union(enum) {
        file: void,
        directory: DirIterator,
    },

    pub fn getEntryName(entry: @This()) []const u8 {
        return if (std.mem.lastIndexOfScalar(u8, entry.full_path, '/')) |idx| entry.full_path[idx + 1 ..] else entry.full_path;
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{t}: {s}", .{ self.kind, self.full_path });
    }
};

pub const DirIterator = struct {
    parent_path: []const u8,
    sorted_map: *const FileRecordMap,
    dir_range: struct { usize, usize },
    index: usize = 0,

    const empty_map: FileRecordMap = .init(undefined);

    pub const empty: DirIterator = .{
        .parent_path = "",
        .sorted_map = &empty_map,
        .dir_range = .{ 0, 0 },
    };

    pub fn next(self: *DirIterator) ?EntryT {
        if (self.index >= self.dir_range.@"1" - self.dir_range.@"0")
            return null;

        const dir = self.sorted_map.file_records.keys()[self.dir_range.@"0"..self.dir_range.@"1"];
        const first_key = dir[self.index].key;
        if (std.mem.indexOfScalarPos(u8, first_key, self.parent_path.len + 1, '/')) |next_dir_slash| {
            const dir_path = first_key[0..next_dir_slash];
            const dir_range = self.sorted_map.sortedMapGetDirRangeBounded(dir_path, self.dir_range);
            self.index = dir_range.@"1";

            return .{
                .full_path = dir_path,
                .kind = .{ .directory = .{
                    .parent_path = dir_path,
                    .sorted_map = self.sorted_map,
                    .dir_range = dir_range,
                } },
            };
        } else {
            self.index += 1;
            return .{
                .full_path = first_key,
                .kind = .{ .file = {} },
            };
        }
    }
};

test "get dir from file records" {
    const allocator = std.testing.allocator;
    var frmap: FileRecordMap = .init(allocator);
    defer frmap.deinit();

    const generic_chunk: FileRecordMap.FileChunk = .{
        .blk_id = "blemblem".*,
        .blk_offset = 0,
        .length = 1,
    };

    const generic_file_record: FileRecordMap.FileRecord = .{
        .length = 1,
        .num_blks = 1,
        .chunks = &.{generic_chunk},
        .opts = .{
            .deleted = false,
        },
        .path = "owo",
        .pfix_id = 0,
        .tstamp = .{
            .mod_dev_id = 0,
            .mod_time = 0,
        },
    };

    try frmap.put(.borrowed("bar/owo/foo.txt"), generic_file_record);
    try frmap.put(.borrowed("owo/bar.txt"), generic_file_record);
    try frmap.put(.borrowed("foo/foo"), generic_file_record);
    try frmap.put(.borrowed("bar/owo/bar.txt"), generic_file_record);
    try frmap.put(.borrowed("bar/baz/foo.txt"), generic_file_record);
    try frmap.put(.borrowed("uwu/owo/test.txt"), generic_file_record);

    frmap.sort();

    {
        const range = frmap.sortedMapGetDirRange("bar/owo");
        const dir_keys = frmap.file_records.keys()[range.@"0"..range.@"1"];
        try std.testing.expectEqual(2, dir_keys.len);
        try std.testing.expectEqualStrings("bar/owo/bar.txt", dir_keys[0].key);
        try std.testing.expectEqualStrings("bar/owo/foo.txt", dir_keys[1].key);
    }

    {
        const range = frmap.sortedMapGetDirRange("owo/bar.txt");
        const dir_keys = frmap.file_records.keys()[range.@"0"..range.@"1"];
        try std.testing.expectEqual(1, dir_keys.len);
        try std.testing.expectEqualStrings("owo/bar.txt", dir_keys[0].key);
    }
}
