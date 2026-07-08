const std = @import("std");
const builin = @import("builtin");

pub const endl = switch (builin.os.tag) {
    .windows => "\r\n",
    else => "\n",
};
