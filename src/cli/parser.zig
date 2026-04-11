const std = @import("std");

pub const ShortFlagResult = struct {
    found: bool,
    cluster_first: ?bool,
};

pub fn containsShortFlag(word: []const u8, flag: u8) ShortFlagResult {
    const idx = std.mem.indexOfScalar(u8, word, flag);
    return .{
        .found = word.len > 1 and word[0] == '-' and word[1] != '-' and idx != null,
        .cluster_first = if (word.len != 2 and idx != null) idx.? == 1 else null,
    };
}

pub const IndexOfOptResult = struct {
    value: union(enum) {
        flag: ShortFlagResult,
        option: void,
    },
    idx: usize,
};

pub fn indexOfOption(args: []const []const u8, option: []const u8, short_flag: ?u8) ?IndexOfOptResult {
    return for (args, 0..) |arg, i| {
        if (short_flag) |f| {
            const sfres = containsShortFlag(arg, f);
            if (sfres.found) {
                break .{
                    .value = .{ .flag = sfres },
                    .idx = i,
                };
            }
        }

        if (std.mem.startsWith(u8, arg, option)) {
            break .{
                .value = .{ .option = {} },
                .idx = i,
            };
        }
    } else null;
}

pub fn indexOfOptionAfter(args: []const []const u8, needle: []const u8, option: []const u8, short_flag: ?u8) ?IndexOfOptResult {
    const idx = for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, needle))
            break i;
    } else return null;

    var res = indexOfOption(args[idx..], option, short_flag);
    return if (res) |*r| blk: {
        r.idx += idx;
        break :blk r.*;
    } else null;
}

pub fn getAssociatedValue(args: []const []const u8, option: []const u8, short_flag: ?u8, eql_sign: bool) ?[]const u8 {
    if (indexOfOption(args, option, short_flag)) |res| {
        switch (res.value) {
            .flag => |flag_res| if (flag_res.cluster_first) |cf| if (!cf) return null,
            else => {},
        }

        if (eql_sign) {
            const key_val = args[res.idx];
            return key_val[(std.mem.indexOfScalar(u8, key_val, '=') orelse return null) + 1 ..];
        } else {
            if (res.idx + 1 < args.len)
                return args[res.idx + 1];

            return null;
        }
    } else return null;
}

test "short flag" {
    const word1 = "owo";
    const word2 = "-ow";
    const word3 = "--verbose";
    const word4 = "-asdfghjk";

    try std.testing.expect(containsShortFlag(word1, 'o').found == false);
    try std.testing.expectEqualDeep(ShortFlagResult{ .found = true, .cluster_first = true }, containsShortFlag(word2, 'o'));
    try std.testing.expect(containsShortFlag(word3, 'v').found == false);
    try std.testing.expectEqualDeep(ShortFlagResult{ .found = true, .cluster_first = false }, containsShortFlag(word4, 'j'));
}

test "option after" {
    const args1 = &.{ "zig", "-o", "build", "-h" };
    const args2 = &.{ "dergdrive", "sync", "-v", "-s=sf", "--pull=nd", "-o", "dotfiles" };

    try std.testing.expectEqual(1, indexOfOption(args1, "opt", 'o').?.idx);
    try std.testing.expect(indexOfOptionAfter(args1, "build", "opt", 'o') == null);
    try std.testing.expectEqual(3, indexOfOptionAfter(args1, "build", "help", 'h').?.idx);

    try std.testing.expect(indexOfOption(args2, "dumb", 'd') == null);
    try std.testing.expectEqualStrings("sf", getAssociatedValue(args2, "push", 's', true).?);
    try std.testing.expectEqualStrings("nd", getAssociatedValue(args2, "--pull", 'l', true).?);
    try std.testing.expectEqualStrings("dotfiles", getAssociatedValue(args2, "vol", 'o', false).?);
}
