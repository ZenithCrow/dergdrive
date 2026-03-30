const std = @import("std");
const Mutex = std.Thread.Mutex;

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
w_lock: Mutex = .{},

pub fn init(allocator: std.mem.Allocator) FileRecordMap {
    return .{
        .file_records = .init(allocator),
    };
}

pub fn deinit(self: *FileRecordMap) void {
    self.w_lock.lock();
    defer self.w_lock.unlock();

    for (self.file_records.keys()) |key| {
        if (key.owned)
            self.file_records.allocator.free(key.key);
    }
    self.file_records.deinit();
}

pub inline fn clear(self: *FileRecordMap) void {
    self.w_lock.lock();
    defer self.w_lock.unlock();

    self.file_records.clearRetainingCapacity();
    self.sorted = false;
}

pub inline fn put(self: *FileRecordMap, key: FileRecordKey, val: FileRecord) std.mem.Allocator.Error!void {
    self.w_lock.lock();
    defer self.w_lock.unlock();

    try self.file_records.put(key, val);
    self.sorted = false;
}

pub fn sort(self: *FileRecordMap) void {
    self.w_lock.lock();
    defer self.w_lock.unlock();

    self.file_records.sort(struct {
        self: *FileRecordHashMap,

        pub fn lessThan(ctx: @This(), a_i: usize, b_i: usize) bool {
            const keys = ctx.self.keys();
            return std.mem.lessThan(u8, keys[a_i].key, keys[b_i].key);
        }
    }{ .self = &self.file_records });
}

pub fn getDirRange(self: *FileRecordMap, dir_path: []const u8) struct { usize, usize } {
    self.w_lock.lock();
    defer self.w_lock.unlock();

    if (!self.sorted) {
        self.w_lock.unlock();
        self.sort();
        self.w_lock.lock();
    }

    return std.sort.equalRange(FileRecordKey, self.file_records.keys(), dir_path, struct {
        pub fn compareFn(context: []const u8, item: FileRecordKey) std.math.Order {
            if (std.mem.startsWith(u8, item.key, context))
                return std.math.Order.eq;

            return std.mem.order(u8, context, item.key);
        }
    }.compareFn);
}

pub fn getDir(self: *FileRecordMap, dir_path: []const u8) []FileRecord {
    const range = self.getDirRange(dir_path);
    return self.file_records.values()[range.@"0"..range.@"1"];
}

test "get dir from file records" {
    const allocator = std.testing.allocator;
    var frmap: FileRecordMap = .init(allocator);
    defer frmap.deinit();

    const generic_file_record: FileRecord = .{
        .tstamp = .{ .mod_dev_id = 0, .mod_time = 0 },
        .blk_idx = 0,
        .length = 1,
        .offset = 0,
        .path = "owo",
        .pfix_id = 0,
    };

    try frmap.put(.borrowed("bar/owo/foo.txt"), generic_file_record);
    try frmap.put(.borrowed("owo/bar.txt"), generic_file_record);
    try frmap.put(.borrowed("foo/foo"), generic_file_record);
    try frmap.put(.borrowed("bar/owo/bar.txt"), generic_file_record);
    try frmap.put(.borrowed("bar/baz/foo.txt"), generic_file_record);
    try frmap.put(.borrowed("uwu/owo/test.txt"), generic_file_record);

    {
        const range = frmap.getDirRange("bar/owo");
        const dir_keys = frmap.file_records.keys()[range.@"0"..range.@"1"];
        try std.testing.expectEqual(2, dir_keys.len);
        try std.testing.expectEqualStrings("bar/owo/bar.txt", dir_keys[0].key);
        try std.testing.expectEqualStrings("bar/owo/foo.txt", dir_keys[1].key);
    }

    {
        const range = frmap.getDirRange("owo/bar.txt");
        const dir_keys = frmap.file_records.keys()[range.@"0"..range.@"1"];
        try std.testing.expectEqual(1, dir_keys.len);
        try std.testing.expectEqualStrings("owo/bar.txt", dir_keys[0].key);
    }
}
