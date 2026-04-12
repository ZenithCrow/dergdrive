const std = @import("std");

pub const Decoration = enum {
    red,
    bred,
    green,
    bgreen,
    blue,
    yellow,
    byellow,
    bblue,
    dim,
    bold,
    underline,
    italic,
};

const esc: u8 = '\x1b';

pub fn printDecorated(fw: *std.Io.Writer, decorate: bool, decor: []const Decoration, comptime fmt: []const u8, args: anytype) void {
    if (decorate) {
        for (decor) |d| {
            fw.print("\x1b[{s}", .{switch (d) {
                .red => "31m",
                .bred => "91m",
                .green => "32m",
                .bgreen => "92m",
                .blue => "34m",
                .bblue => "94m",
                .yellow => "33m",
                .byellow => "93m",
                .dim => "2m",
                .bold => "1m",
                .underline => "4m",
                .italic => "3m",
            }}) catch return;
        }
    }

    fw.print(fmt, args) catch return;
    fw.writeAll("\x1b[0m") catch return;
}
