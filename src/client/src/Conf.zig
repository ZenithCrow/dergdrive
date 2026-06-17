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
const g_oride_prefixes: RootConf.ConfFile = .{ .nspace = .from(.{ .config = .vol }), .sub_path = "prefix_overrides.cfg" };
const g_known_hosts: RootConf.ConfFile = .{ .nspace = .{ .nspace = .{ .config = .user } }, .sub_path = "known_hosts.cfg" };
const g_access_tokens: RootConf.ConfFile = .{ .nspace = .{ .nspace = .{ .pers = .secret } }, .sub_path = "access_tokens" };

root_conf: RootConf,
mfest_cache: RootConf.ConfFile = g_mfest_cache,
oride_prefixes: RootConf.ConfFile = g_oride_prefixes,
known_hosts: RootConf.ConfFile = g_known_hosts,
access_tokens: RootConf.ConfFile = g_access_tokens,

pub fn init(vol: []const u8, emap: *const std.process.Environ.Map) Conf {
    return .{ .root_conf = .{
        .emap = emap,
        .conf_file_hierarchy = g_conf_file_hierarchy_client,
        .vol = vol,
    } };
}
