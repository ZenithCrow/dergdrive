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

pub const FindInKnownHostsResult = struct {
    last_match: ?[]const u8,
    key_match: bool,

    pub fn deinit(self: FindInKnownHostsResult, gpa: std.mem.Allocator) void {
        if (self.last_match) |lm| gpa.free(lm);
    }
};

pub fn findPubSignKeyInKnownHosts(self: Conf, host_id: SecAuth.HostIdentification, key: SignAlgo.PublicKey, gpa: std.mem.Allocator, io: std.Io) RootConf.GetConfError!FindInKnownHostsResult {
    const encoder = std.base64.standard.Encoder;
    const b64_key_len = comptime encoder.calcSize(SignAlgo.PublicKey.encoded_length);
    var b64_key_buf: [b64_key_len]u8 = undefined;
    const b64_key = encoder.encode(&b64_key_buf, &key.toBytes());

    const known_hosts_buf = try self.root_conf.getConf(self.known_hosts, gpa, io);
    defer gpa.free(known_hosts_buf);

    var result: FindInKnownHostsResult = .{
        .last_match = null,
        .key_match = false,
    };

    var iter: RootConf.PublicSignKeyIterator = .fromBuf(known_hosts_buf, host_id.host_name, host_id.ip_addr);
    while (iter.next()) |kv| : (result.last_match = kv.host) {
        const possible_match_msg_base = "Found possible host match for";
        if (host_id.host_name) |hn| {
            log.debug(possible_match_msg_base ++ " '{s}' ({f}): '{s}'.", .{ hn, host_id.ip_addr, kv.host });
        } else log.debug(possible_match_msg_base ++ " {f}: {s}", .{ host_id.ip_addr, kv.host });

        if (std.mem.eql(u8, &kv.pub_key.toBytes(), b64_key))
            return .{ .last_match = try gpa.dupe(u8, kv.host), .key_match = true };
    }

    if (result.last_match) |lm| result.last_match = try gpa.dupe(u8, lm);
    return result;
}
