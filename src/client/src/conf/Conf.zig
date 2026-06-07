const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const RootConf = dergdrive.conf.Conf;

const Conf = @This();

const g_conf_file_hierarchy_client: []const RootConf.ConfFile = RootConf.g_conf_file_hierarchy ++ switch (builtin.os.tag) {
    .linux => &[_]RootConf.ConfFile{
        .{ .nspace = .from(.{ .config = .vol }), .sub_path = RootConf.config_filename, .always_create = false },
    },
    else => @compileError("implement mee >w< uhgmmm.."),
};

const g_mfest_cache: RootConf.ConfFile = .{ .nspace = .from(.{ .cache = .vol }), .sub_path = "manifest" };
const g_oride_prefixes: RootConf.ConfFile = .{ .nspace = .from(.{ .config = .vol }), .sub_path = "prefix-overrides.ini" };

root_conf: RootConf,
mfest_cache: RootConf.ConfFile = g_mfest_cache,
oride_prefixes: RootConf.ConfFile = g_oride_prefixes,

pub fn init(vol: []const u8, emap: *const std.process.Environ.Map) Conf {
    return .{ .root_conf = .{
        .emap = emap,
        .conf_file_hierarchy = g_conf_file_hierarchy_client,
        .vol = vol,
    } };
}
