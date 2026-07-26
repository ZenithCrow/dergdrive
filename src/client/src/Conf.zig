const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const RootConf = dergdrive.conf.Conf;
const SecAuth = dergdrive.SecAuth;
const SignAlgo = dergdrive.crypt.SignAlgo;

const Conf = @This();

const log = std.log.scoped(.@"client/Conf");

const g_conf_file_hierarchy_client: []const RootConf.ConfFile = RootConf.g_conf_file_hierarchy ++ switch (builtin.os.tag) {
    .linux, .windows => &[_]RootConf.ConfFile{
        .{ .nspace = .from(.{ .config = .vol }), .sub_path = RootConf.config_filename, .always_create = false },
    },
    else => @compileError("implement mee >w< uhgmmm.."),
};

const g_mfest_cache: RootConf.ConfFile = .{ .nspace = .from(.{ .cache = .vol }), .sub_path = "manifest" };
const g_oride_prefixes: RootConf.ConfFile = .{ .nspace = .from(.{ .config = .vol }), .sub_path = "prefix_overrides.cfg" };
const g_known_hosts: RootConf.ConfFile = .{ .nspace = .from(.{ .config = .user }), .sub_path = "known_hosts.cfg" };
const g_access_tokens: RootConf.ConfFile = .{ .nspace = .from(.{ .pers = .secret }), .sub_path = "access_tokens" };

root_conf: RootConf = .{ .emap = undefined },
mfest_cache: RootConf.ConfFile = g_mfest_cache,
oride_prefixes: RootConf.ConfFile = g_oride_prefixes,
known_hosts: RootConf.ConfFile = g_known_hosts,
access_tokens: RootConf.ConfFile = g_access_tokens,

pub fn init(self: *Conf, vol: []const u8, emap: *const std.process.Environ.Map, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    self.root_conf.emap = emap;
    self.root_conf.vol = vol;
    try self.root_conf.init(gpa);

    try self.mfest_cache.init(self.root_conf, gpa);
    try self.oride_prefixes.init(self.root_conf, gpa);
    try self.known_hosts.init(self.root_conf, gpa);
    try self.access_tokens.init(self.root_conf, gpa);
}

pub fn deinit(self: Conf, gpa: std.mem.Allocator) void {
    self.mfest_cache.deinit(gpa);
    self.oride_prefixes.deinit(gpa);
    self.known_hosts.deinit(gpa);
    self.access_tokens.deinit(gpa);

    self.root_conf.deinit(gpa);
}

pub const FindInKnownHostsResult = struct {
    last_match: ?[]const u8,
    last_match_key: ?SignAlgo.PublicKey,
    key_match: bool,

    pub fn deinit(self: FindInKnownHostsResult, gpa: std.mem.Allocator) void {
        if (self.last_match) |lm| gpa.free(lm);
    }
};

pub fn findPubSignKeyInKnownHosts(self: Conf, host_id: SecAuth.HostIdentification, key: SignAlgo.PublicKey, gpa: std.mem.Allocator, io: std.Io) RootConf.GetConfError!FindInKnownHostsResult {
    const known_hosts_buf = try self.known_hosts.getContent(gpa, io);
    defer gpa.free(known_hosts_buf);

    var result: FindInKnownHostsResult = .{
        .last_match = null,
        .last_match_key = null,
        .key_match = false,
    };

    var iter: RootConf.PublicSignKeyIterator = .fromBuf(known_hosts_buf, host_id.host_name, host_id.ip_addr);
    while (iter.next()) |kv| : ({
        result.last_match = kv.host;
        result.last_match_key = kv.pub_key;
    }) {
        log.debug("Found possible host match for {f}: '{s}'.", .{ host_id, kv.host });

        if (std.mem.eql(u8, &kv.pub_key.toBytes(), &key.toBytes()))
            return .{ .last_match = try gpa.dupe(u8, kv.host), .last_match_key = kv.pub_key, .key_match = true };
    }

    if (result.last_match) |lm| result.last_match = try gpa.dupe(u8, lm);
    return result;
}
