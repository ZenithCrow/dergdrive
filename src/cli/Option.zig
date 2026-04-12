const std = @import("std");

const cli = @import("dergdrive").cli;

pub const Value = struct {
    eql_sign: bool,
    default: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

long: []const u8,
short: ?u8 = null,
desc: []const u8,
value: ?Value = null,

pub fn getValue(self: @This(), args: []const []const u8) ?[]const u8 {
    return if (self.value) |val| cli.parser.getAssociatedValue(args, self.long, self.short, val.eql_sign) else null;
}

pub const opt_not_set_template = "{s} needs to be specified for this operation. Set it via '{s}' config option or '{s}' cli option.";
