const std = @import("std");

fn SlcWithOwnership(comptime T: type, comptime is_const: bool) type {
    return struct {
        const SlcT = if (is_const) []const T else []T;

        slc: SlcT,
        allocator: ?std.mem.Allocator,

        pub fn borrowed(slc: SlcT) @This() {
            return .{
                .slc = slc,
                .allocator = null,
            };
        }

        pub fn owned(slc: SlcT, allocator: std.mem.Allocator) @This() {
            return .{
                .slc = slc,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: @This()) void {
            if (self.allocator) |a| {
                a.free(self.slc);
            }
        }
    };
}

pub fn SliceWithOwnerShip(comptime T: type) type {
    return SlcWithOwnership(T, false);
}

pub fn SliceConstWithOwnerShip(comptime T: type) type {
    return SlcWithOwnership(T, true);
}
