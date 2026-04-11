const std = @import("std");

pub const Value = struct {
    optional: bool,
};

long: []const u8,
short: ?u8 = null,
desc: []const u8,
value: ?union(enum) {
    eql_sign: Value,
    none: Value,
} = null,
