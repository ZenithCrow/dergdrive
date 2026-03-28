const std = @import("std");

const Manifest = @import("Manifest.zig");

const FileRecordMap = @This();

pub const FileRecord = struct {
    path: []const u8,
    tstamp: Manifest.Timestamp,
    pfix_id: u32,
    blk_idx: u32,
    offset: u32,
    length: u64,

    pub fn format(self: FileRecord, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll(self.path);
        try writer.writeInt(u8, 0, .little);
        try self.tstamp.format(writer);
        try writer.writeInt(u32, self.pfix_id, .little);
        try writer.writeInt(u32, self.blk_idx, .little);
        try writer.writeInt(u32, self.offset, .little);
        try writer.writeInt(u64, self.length, .little);
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

const FileRecordHashMap = std.ArrayHashMap(FileRecordKey, FileRecord, FileRecordContext, true);

file_records: FileRecordHashMap,
sorted: bool = false,

pub fn init(allocator: std.mem.Allocator) FileRecordMap {
    return .{
        .file_records = .init(allocator),
    };
}

pub fn deinit(self: *FileRecordMap) void {
    for (self.file_records.keys()) |key| {
        if (key.owned)
            self.file_records.allocator.free(key.key);
    }
    self.file_records.deinit();
}

pub inline fn clear(self: *FileRecordMap) void {
    self.file_records.clearRetainingCapacity();
    self.sorted = false;
}

pub inline fn put(self: *FileRecordMap, key: FileRecordKey, val: FileRecord) std.mem.Allocator.Error!void {
    try self.file_records.put(key, val);
    self.sorted = false;
}

pub fn getDir(self: *FileRecordMap, dir_path: []const u8) []FileRecord {
    if (!self.sorted) {
        self.file_records.sort(struct {
            self: *FileRecordHashMap,

            pub fn lessThan(ctx: @This(), a_i: usize, b_i: usize) bool {
                const keys = ctx.self.keys();
                return std.mem.lessThan(u8, keys[a_i].key, keys[b_i].key);
            }
        }{ .self = &self.file_records });
    }

    const range = std.sort.equalRange(FileRecordKey, self.file_records.keys(), dir_path, struct {
        pub fn compareFn(context: []const u8, item: FileRecordKey) std.math.Order {
            return std.mem.order(u8, context, item.key);
        }
    }.compareFn);

    return self.file_records.values()[range.@"0"..range.@"1"];
}
