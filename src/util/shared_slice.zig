const std = @import("std");

pub fn SharedSlice(comptime T: type) type {
    return struct {
        ref_count: usize,
        slice: []const T,
        gpa: std.mem.Allocator,

        pub fn init(str: []const T, gpa: std.mem.Allocator) @This() {
            return .{
                .ref_count = 1,
                .slice = str,
                .gpa = gpa,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.ref_count > 0) {
                self.ref_count -= 1;

                if (self.ref_count == 0)
                    self.gpa.free(self.slice);
            }
        }

        pub fn deinitAll(self: *@This()) void {
            if (self.ref_count > 0)
                self.gpa.free(self.slice);
        }

        pub fn ref(self: *@This()) *@This() {
            self.ref_count += 1;
            return self;
        }
    };
}

pub const SharedString = SharedSlice(u8);

pub const SharedStringStorage = struct {
    storage: std.array_hash_map.String(SharedString),

    pub const empty: @This() = .{
        .storage = .empty,
    };

    pub fn deinitMapOnly(self: *@This(), gpa: std.mem.Allocator) void {
        self.storage.deinit(gpa);
    }

    pub fn deinitAll(self: *@This(), gpa: std.mem.Allocator) void {
        for (self.storage.values()) |*entry| {
            entry.deinitAll();
        }

        self.deinitMapOnly(gpa);
    }

    pub fn getOrPut(self: *@This(), str: []const u8, gpa: std.mem.Allocator) std.mem.Allocator.Error!*SharedString {
        return if (self.storage.contains(str)) self.storage.getPtr(str).? else blk: {
            var val: SharedString = .init(try gpa.dupe(u8, str), gpa);
            const res = try self.storage.getOrPut(gpa, val.ref().slice);
            res.value_ptr.* = val;

            break :blk res.value_ptr;
        };
    }

    pub fn deinitStr(self: *@This(), str: *SharedString) void {
        str.deinit();
        if (str.ref_count == 1) {
            var tmp_str = str.*;
            _ = self.storage.swapRemove(str.slice);
            tmp_str.deinit();
        }
    }
};
