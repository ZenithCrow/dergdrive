const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const RootConf = dergdrive.conf.Conf;
const ConfFile = RootConf.ConfFile;

const Conf = @This();

const g_private_sign_key: ConfFile = .{ .nspace = .from(.{ .pers = .secret }), .sub_path = "priv_sign_key" };
const g_public_sign_key: ConfFile = .{ .nspace = .from(.{ .pers = .secret }), .sub_path = "pub_sign_key" };

root_conf: RootConf,
private_sign_key: ConfFile = g_private_sign_key,
public_sign_key: ConfFile = g_public_sign_key,

pub fn init(emap: *const std.process.Environ.Map) Conf {
    return .{ .root_conf = .{
        .emap = emap,
        .conf_file_hierarchy = RootConf.g_conf_file_hierarchy,
    } };
}
