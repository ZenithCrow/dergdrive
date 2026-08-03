const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const RootConf = dergdrive.conf.Conf;
const ConfFile = RootConf.ConfFile;

const Conf = @This();

const g_private_sign_key: ConfFile = .{ .nspace = .from(.{ .pers = .secret }), .sub_path = "priv_sign_key" };
const g_public_sign_key: ConfFile = .{ .nspace = .from(.{ .pers = .secret }), .sub_path = "pub_sign_key" };

root_conf: RootConf = .{ .emap = undefined },
private_sign_key: ConfFile = g_private_sign_key,
public_sign_key: ConfFile = g_public_sign_key,

pub fn init(self: *Conf, emap: *const std.process.Environ.Map, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    self.root_conf.emap = emap;
    try self.root_conf.init(gpa);

    try self.private_sign_key.init(self.root_conf, gpa);
    try self.public_sign_key.init(self.root_conf, gpa);
}

pub fn deinit(self: Conf, gpa: std.mem.Allocator) void {
    self.private_sign_key.deinit(gpa);
    self.public_sign_key.deinit(gpa);

    self.root_conf.deinit(gpa);
}
