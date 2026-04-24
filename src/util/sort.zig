const std = @import("std");

pub fn @"human -- ehm well derg- naturalCharLessThan"(a: u8, b: u8) std.math.Order {
    const al = std.ascii.toLower(a);
    const bl = std.ascii.toLower(b);
    return if (al != bl) std.math.order(al, bl) else std.math.order(a, b);
}

pub fn humanStringOrder(lhs_p: []const u8, rhs_p: []const u8) std.math.Order {
    const lhs = if (lhs_p.len > 1 and lhs_p[0] == '.') lhs_p[1..] else lhs_p;
    const rhs = if (rhs_p.len > 1 and rhs_p[0] == '.') rhs_p[1..] else rhs_p;

    const n = @min(lhs.len, rhs.len);
    for (lhs[0..n], rhs[0..n]) |lhs_elem, rhs_elem| {
        switch (@"human -- ehm well derg- naturalCharLessThan"(lhs_elem, rhs_elem)) {
            .eq => continue,
            else => |o| return o,
        }
    }
    return std.math.order(lhs.len, rhs.len);
}

pub inline fn humanStringLessThan(lhs: []const u8, rhs: []const u8) bool {
    return humanStringOrder(lhs, rhs) == .lt;
}
