const std = @import("std");
const net = std.Io.net;
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const util = dergdrive.util;
const SecAuth = dergdrive.SecAuth;
const SignAlgo = dergdrive.crypt.SignAlgo;
const connection_service = dergdrive.client.rxtx.connection_service;
pub const proj_name: []const u8 = dergdrive.cli.command_exec.prog_name;

const Conf = @This();

const log = std.log.scoped(.@"conf/Conf");

pub const GetFileContentError = std.Io.File.StatError || std.mem.Allocator.Error || std.Io.File.Reader.Error;
pub const GetFileContentFromPathError = GetFileContentError || std.Io.File.OpenError;
pub const OpenOrCreateConfFileError = std.Io.Dir.CreateDirPathOpenError || std.Io.Dir.OpenError || std.Io.Dir.StatError || std.Io.File.OpenError || std.mem.Allocator.Error || std.Io.File.SetPermissionsError;
pub const WriteConfFileError = OpenOrCreateConfFileError || std.Io.File.WritePositionalError;
pub const GetConfError = GetFileContentError || GetFileContentFromPathError || OpenOrCreateConfFileError;
pub const SetError = GetFileContentError || OpenOrCreateConfFileError || std.Io.File.SeekError || std.Io.File.SetLengthError || std.Io.File.Writer.Error;

const pers_internal: []const u8 = ".share";
const cache_internal: []const u8 = ".cache";
const config_internal: []const u8 = ".config";

const config_global_linux: []const u8 = "/etc/" ++ proj_name;
const config_user_linux: []const u8 = "$XDG_CONFIG_HOME/" ++ proj_name;
const config_user_linux_xdg_resort: []const u8 = "~/.config";
const config_vol_linux: []const u8 = config_user_linux ++ "/{vol}";
const cache_user_linux: []const u8 = "~/.cache/" ++ proj_name;
const cache_vol_linux: []const u8 = cache_user_linux ++ "/{vol}";
const pers_global_linux: []const u8 = "/usr/share/" ++ proj_name;
const pers_user_linux: []const u8 = "$XDG_DATA_HOME/" ++ proj_name;
const pers_user_linux_xdg_resort: []const u8 = "~/.local/share";
const pers_user_secret_linux: []const u8 = pers_user_linux ++ "/secret";
const pers_vol_linux: []const u8 = pers_user_linux ++ "/{vol}";
const pers_vol_secret_linux: []const u8 = pers_vol_linux ++ "/secret";

const config_global_windows: []const u8 = pers_global_windows ++ "\\config";
const config_user_windows: []const u8 = "%APPDATA%\\" ++ proj_name;
const config_vol_windows: []const u8 = config_user_windows ++ "\\{vol}";
const cache_user_windows: []const u8 = "%TEMP%\\" ++ proj_name;
const cache_vol_windows: []const u8 = cache_user_windows ++ "\\{vol}";
const pers_global_windows: []const u8 = "%PROGRAMDATA%\\" ++ proj_name;
const pers_user_windows: []const u8 = "%LOCALAPPDATA%\\" ++ proj_name;
const pers_user_secret_windows: []const u8 = pers_user_windows ++ "\\secret";
const pers_vol_windows: []const u8 = pers_user_windows ++ "\\{vol}";
const pers_vol_secret_windows: []const u8 = pers_vol_windows ++ "\\secret";

pub const ConfPrefix = struct {
    config_global_linux: []const u8 = config_global_linux,
    config_user_linux: []const u8 = config_user_linux,
    config_vol_linux: []const u8 = config_vol_linux,
    config_internal: []const u8 = config_internal,
    cache_user_linux: []const u8 = cache_user_linux,
    cache_vol_linux: []const u8 = cache_vol_linux,
    cache_internal: []const u8 = cache_internal,
    pers_global_linux: []const u8 = pers_global_linux,
    pers_user_linux: []const u8 = pers_user_linux,
    pers_user_secret_linux: []const u8 = pers_user_secret_linux,
    pers_vol_local_linux: []const u8 = pers_vol_linux,
    pers_vol_secret_linux: []const u8 = pers_vol_secret_linux,
    pers_internal: []const u8 = pers_internal,

    config_global_windows: []const u8 = config_global_windows,
    config_user_windows: []const u8 = config_user_windows,
    config_vol_windows: []const u8 = config_vol_windows,
    cache_user_windows: []const u8 = cache_user_windows,
    cache_vol_windows: []const u8 = cache_vol_windows,
    pers_global_windows: []const u8 = pers_global_windows,
    pers_user_windows: []const u8 = pers_user_windows,
    pers_user_secret_windows: []const u8 = pers_user_secret_windows,
    pers_vol_windows: []const u8 = pers_vol_windows,
    pers_vol_secret_windows: []const u8 = pers_vol_secret_windows,
};

pub const Nspace = enum {
    global,
    user,
    vol,
    internal,
    secret,
    vol_secret,
};

pub const LocNspace = union(enum) {
    config: Nspace,
    cache: Nspace,
    pers: Nspace,
};

pub const PfixNspace = struct {
    nspace: LocNspace,
    pfix: ConfPrefix = .{},

    pub fn from(nspace: LocNspace) PfixNspace {
        return .{ .nspace = nspace };
    }

    pub fn getRoot(self: PfixNspace) []const u8 {
        return switch (builtin.os.tag) {
            .linux => switch (self.nspace) {
                .config => |nspace| switch (nspace) {
                    .global => self.pfix.config_global_linux,
                    .user => self.pfix.config_user_linux,
                    .vol => self.pfix.config_vol_linux,
                    .internal => self.pfix.config_internal,
                    else => @panic("namespace not supported for config"),
                },
                .cache => |nspace| switch (nspace) {
                    .user => self.pfix.cache_user_linux,
                    .vol => self.pfix.cache_vol_linux,
                    .internal => self.pfix.cache_internal,
                    else => @panic("namespace not supported for cache"),
                },
                .pers => |nspace| switch (nspace) {
                    .global => self.pfix.pers_global_linux,
                    .user => self.pfix.pers_user_linux,
                    .vol => self.pfix.pers_vol_local_linux,
                    .internal => self.pfix.pers_internal,
                    .secret => self.pfix.pers_user_secret_linux,
                    .vol_secret => self.pfix.pers_vol_secret_linux,
                },
            },
            .windows => switch (self.nspace) {
                .config => |nspace| switch (nspace) {
                    .global => self.pfix.config_global_windows,
                    .user => self.pfix.config_user_windows,
                    .vol => self.pfix.config_vol_windows,
                    .internal => self.pfix.config_internal,
                    else => @panic("namespace not supported for config"),
                },
                .cache => |nspace| switch (nspace) {
                    .user => self.pfix.cache_user_windows,
                    .vol => self.pfix.cache_vol_windows,
                    .internal => self.pfix.cache_internal,
                    else => @panic("namespace not supported for cache"),
                },
                .pers => |nspace| switch (nspace) {
                    .global => self.pfix.pers_global_windows,
                    .user => self.pfix.pers_user_windows,
                    .vol => self.pfix.pers_vol_windows,
                    .internal => self.pfix.pers_internal,
                    .secret => self.pfix.pers_user_secret_windows,
                    .vol_secret => self.pfix.pers_vol_secret_windows,
                },
            },
            else => @compileError("implement this for your os if you want it so bad"),
        };
    }
};

pub const ConfFile = struct {
    nspace: PfixNspace,
    sub_path: []const u8,
    always_create: bool = false,
    resolved_path: []const u8 = undefined,

    pub fn init(self: *ConfFile, conf: Conf, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
        self.resolved_path = try self.getFullPath(conf, gpa);
    }

    pub fn deinit(self: ConfFile, gpa: std.mem.Allocator) void {
        gpa.free(self.resolved_path);
    }

    fn getFullPath(self: ConfFile, conf: Conf, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const root_path = self.nspace.getRoot();
        const expanded = try conf.expand(root_path, allocator);
        defer allocator.free(expanded);
        return std.mem.join(allocator, "/", &.{ expanded, self.sub_path });
    }

    pub fn openOrCreate(conf_file: ConfFile, truncate: bool, io: std.Io) OpenOrCreateConfFileError!std.Io.File {
        const full_path = conf_file.resolved_path;

        const last_slash = std.mem.lastIndexOfScalar(u8, full_path, '/');
        const dir_path = full_path[0 .. last_slash orelse 0];

        const file_delim = if (last_slash) |pos| pos + 1 else 0;
        const file_path = full_path[file_delim..];

        var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
        defer dir.close(io);

        const file = try dir.createFile(io, file_path, .{ .read = true, .truncate = truncate });
        errdefer file.close(io);

        if (builtin.os.tag != .windows) {
            switch (conf_file.nspace.nspace) {
                .cache, .config, .pers => |nspace| if (nspace == .secret) try file.setPermissions(io, .fromMode(0o600)),
            }
        }

        return file;
    }

    pub fn getContent(self: ConfFile, allocator: std.mem.Allocator, io: std.Io) GetConfError![]const u8 {
        return if (self.always_create) getFileContent(try self.openOrCreate(false, io), allocator, io) else {
            return getFileContentFromPath(self.resolved_path, allocator, io);
        };
    }

    pub fn write(self: ConfFile, truncate: bool, data: []const u8, io: std.Io) WriteConfFileError!void {
        const file = try self.openOrCreate(truncate, io);
        errdefer file.close(io);

        var writer = file.writer(io, &.{});
        return writer.interface.writeAll(data) catch writer.err.?;
    }

    pub fn getKeyValue(self: ConfFile, key: []const u8, gpa: std.mem.Allocator, io: std.Io) GetConfError!?[]const u8 {
        const iter: KeyValueIterator = .init(try self.getContent(gpa, io));
        defer gpa.free(iter.line_iter.buffer);
        return if (getKeyValueFromIter(iter, key)) |value| try gpa.dupe(u8, value) else null;
    }

    pub fn getKeyValueFromIter(kv_iter: KeyValueIterator, key: []const u8) ?[]const u8 {
        var iter_cpy = kv_iter;
        iter_cpy.line_iter.index = 0;
        return while (iter_cpy.next()) |entry| {
            if (std.mem.eql(u8, entry.key, key))
                break entry.value;
        } else null;
    }

    pub fn setKeyValue(self: ConfFile, key: []const u8, value: []const u8, allocator: std.mem.Allocator, io: std.Io) SetError!void {
        const file = try self.openOrCreate(false, io);
        defer file.close(io);
        const buf = try getFileContent(file, allocator, io);
        defer allocator.free(buf);
        var iter: KeyValueIterator = .init(buf);

        var writer = file.writer(io, &.{});

        var key_len: usize = 0;
        var val_len: usize = 0;
        var index: usize = 0;
        const insert = while (iter.next()) |entry| : ({
            if (iter.line_iter.index) |i|
                index = i;
        }) {
            if (std.mem.eql(u8, entry.key, key)) {
                key_len = entry.key.len;
                val_len = entry.value.len;
                index = entry.key.ptr - buf.ptr;
                break true;
            }
        } else false;

        if (insert) {
            const tail_index = index + key_len + val_len + 1;
            const len_diff: isize = @as(isize, @bitCast(value.len)) - @as(isize, @bitCast(val_len));
            const new_len: usize = @bitCast(@as(isize, @bitCast(buf.len)) + len_diff);

            writer.seekTo(index + key_len + 1) catch return writer.seek_err.?;
            writer.interface.writeAll(value) catch return writer.err.?;
            writer.interface.writeAll(buf[tail_index..]) catch return writer.err.?;
            try file.setLength(io, new_len);
        } else {
            const end = try file.length(io);
            const line_break = buf.len > 0 and buf[buf.len - 1] == '\n';

            writer.seekTo(end) catch return writer.seek_err.?;
            if (!line_break)
                writer.interface.writeAll(util.endl) catch return writer.err.?;

            writer.interface.print("{s}={s}\n", .{ key, value }) catch return writer.err.?;
        }
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.writeAll(self.resolved_path);
    }
};

pub const kv_delim: u8 = '=';

pub const KeyValueIterator = struct {
    pub const KVPair = struct {
        key: []const u8,
        value: []const u8,
    };

    line_iter: std.mem.SplitIterator(u8, .any),

    pub fn init(enf_file_buf: []const u8) KeyValueIterator {
        return .{ .line_iter = std.mem.splitAny(u8, enf_file_buf, util.endl) };
    }

    pub fn next(self: *KeyValueIterator) ?KVPair {
        return while (self.line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len > 0 and trimmed[0] != '#') {
                if (std.mem.indexOfScalar(u8, trimmed, kv_delim)) |delim| {
                    return .{
                        .key = line[0..delim],
                        .value = line[delim + 1 ..],
                    };
                }
            }
        } else null;
    }
};

pub const PublicSignKeyIterator = struct {
    pub const PSKKVPair = struct {
        host: []const u8,
        pub_key: SignAlgo.PublicKey,
    };

    iter: KeyValueIterator,
    host_id: SecAuth.HostIdentification,

    pub fn fromBuf(buf: []const u8, host_id: SecAuth.HostIdentification) PublicSignKeyIterator {
        return .{
            .iter = .init(buf),
            .host_id = host_id,
        };
    }

    pub fn next(self: *PublicSignKeyIterator) ?PSKKVPair {
        var ip_addr_buf: [64]u8 = undefined;
        var ip_addr_w: std.Io.Writer = .fixed(&ip_addr_buf);
        self.host_id.ip_addr.format(&ip_addr_w) catch unreachable;
        const ip_addr_str = ip_addr_w.buffered();
        const port_idx = std.mem.findScalarLast(u8, ip_addr_str, ':').?;

        return while (self.iter.next()) |kv| {
            const n = .{ kv.key.len, null };
            const key_port_idx: usize, const key_port_num: ?u16 = if (std.mem.findScalarLast(u8, kv.key, ':')) |kpi|
                if (std.mem.findScalar(u8, kv.key, ':').? == kpi or kpi > 0 and kv.key[kpi - 1] == ']') .{
                    kpi,
                    std.fmt.parseInt(u16, kv.key[kpi + 1 ..], 10) catch |err| {
                        log.warn("Error in key '{s}'. " ++ connection_service.port_num_parse_msg, .{ kv.key, err });
                        continue;
                    },
                } else n
            else
                n;

            const cmp_slc = kv.key[0..key_port_idx];
            const has_hostname_eql = (if (self.host_id.hostname) |hn| std.mem.eql(u8, cmp_slc, hn) else null);
            const ip_addr_eql = std.mem.eql(u8, cmp_slc, ip_addr_str[0..port_idx]);
            const key_has_port_num_eql = if (key_port_num) |kpn| kpn == self.host_id.ip_addr.getPort() else null;

            const match = if (self.host_id.hostname_strict)
                (if (has_hostname_eql) |hhe| hhe else ip_addr_eql) and (key_has_port_num_eql orelse false)
            else
                ((has_hostname_eql orelse false) or ip_addr_eql) and key_has_port_num_eql orelse true;

            if (match) {
                var pub_key_buf: [SignAlgo.PublicKey.encoded_length]u8 = undefined;
                const decoder = std.base64.standard.Decoder;
                const decode_fail_msg = "Failed to decode (base64) public sign key of host '{s}' due to error: {t}.";
                const expected_len = decoder.calcSizeForSlice(kv.value) catch |err| {
                    log.warn(decode_fail_msg, .{ kv.key, err });
                    continue;
                };
                if (expected_len != pub_key_buf.len) {
                    const b64_key_len = comptime std.base64.standard.Encoder.calcSize(SignAlgo.PublicKey.encoded_length);
                    log.warn(decode_fail_msg ++ " Key length in base64 must be {d} characters.", .{ kv.key, error.KeyLenMismatch, b64_key_len });
                    continue;
                }

                decoder.decode(&pub_key_buf, kv.value) catch |err| {
                    log.warn(decode_fail_msg, .{ kv.key, err });
                    continue;
                };

                break .{
                    .host = kv.key,
                    .pub_key = SignAlgo.PublicKey.fromBytes(pub_key_buf[0..SignAlgo.PublicKey.encoded_length].*) catch {
                        log.warn("Ignoring public sign key of host '{s}', because it is not canonical for ED25519.", .{kv.key});
                        continue;
                    },
                };
            }
        } else null;
    }
};

pub const config_filename = "config.cfg";
pub const g_conf_file_default: ConfFile = .{ .nspace = .from(.{ .config = .user }), .sub_path = config_filename, .always_create = true };
pub const g_conf_file_hierarchy: []const ConfFile = switch (builtin.os.tag) {
    .linux, .windows => &.{
        .{ .nspace = .from(.{ .config = .internal }), .sub_path = config_filename, .always_create = false },
        .{ .nspace = .from(.{ .config = .global }), .sub_path = config_filename, .always_create = false },
        g_conf_file_default,
    },
    else => @compileError("implement this for your os if you want it so bad"),
};

conf_file_default: ConfFile = g_conf_file_default,
conf_file_hierarchy_static: []const ConfFile = g_conf_file_hierarchy,
conf_file_hierarchy: []ConfFile = undefined,
emap: *const std.process.Environ.Map,
// default value for compatiblity with server implementation (client should always override it)
vol: []const u8 = "snudoo",

pub fn init(self: *Conf, gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    try self.conf_file_default.init(self.*, gpa);
    self.conf_file_hierarchy = try gpa.dupe(ConfFile, self.conf_file_hierarchy_static);
    for (self.conf_file_hierarchy) |*cf| {
        try cf.init(self.*, gpa);
    }
}

pub fn deinit(self: Conf, gpa: std.mem.Allocator) void {
    self.conf_file_default.deinit(gpa);
    for (self.conf_file_hierarchy) |cf| {
        cf.deinit(gpa);
    }
    gpa.free(self.conf_file_hierarchy);
}

pub fn expand(self: Conf, path: []const u8, gpa: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var var_exp_alloced = false;

    const var_exp = blk: switch (builtin.os.tag) {
        .linux => {
            var iter = std.mem.splitScalar(u8, path, '$');
            var start_str = iter.next().?;

            while (iter.next()) |v| {
                const delim_pos = std.mem.indexOfAny(u8, v, " /") orelse v.len;
                const key = v[0..delim_pos];

                const replace =
                    if (self.emap.get(key)) |r|
                        r
                    else if (std.mem.eql(u8, key, "XDG_CONFIG_HOME"))
                        config_user_linux_xdg_resort
                    else if (std.mem.eql(u8, key, "XDG_DATA_HOME"))
                        pers_user_linux_xdg_resort
                    else
                        key;

                const joint = try std.mem.join(gpa, "", &.{ start_str, replace, v[delim_pos..] });
                if (var_exp_alloced)
                    gpa.free(start_str);

                var_exp_alloced = true;
                start_str = joint;
            }

            if (std.mem.findScalar(u8, start_str, '~') != null) {
                const home =
                    if (self.emap.get("HOME")) |h|
                        h
                    else if (self.emap.get("USERPROFILE")) |h|
                        h
                    else
                        @panic("Home directory could not be inquired.");

                const home_repl = try std.mem.replaceOwned(u8, gpa, start_str, "~", home);
                if (var_exp_alloced)
                    gpa.free(start_str);

                start_str = home_repl;
                var_exp_alloced = true;
            }

            break :blk start_str;
        },
        .windows => {
            var start_idx: usize = 0;
            var str = path;
            while (std.mem.findScalarPos(u8, str, start_idx, '%')) |f_pos| {
                const s_pos = std.mem.findScalarPos(u8, str, f_pos + 1, '%') orelse @panic("missing closing % in env variable");

                const env_var = str[f_pos .. s_pos + 1];
                const key = env_var[1 .. env_var.len - 1];
                const replaced = try std.mem.replaceOwned(u8, gpa, str, env_var, self.emap.get(key) orelse env_var);
                if (var_exp_alloced)
                    gpa.free(str);

                var_exp_alloced = true;
                str = replaced;
                start_idx = s_pos + 1;
            }

            break :blk str;
        },
        else => path,
    };
    defer if (var_exp_alloced) gpa.free(var_exp);

    return std.mem.replaceOwned(u8, gpa, var_exp, "{vol}", self.vol);
}

pub fn getFileContentFromPath(path: []const u8, allocator: std.mem.Allocator, io: std.Io) GetFileContentFromPathError![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return getFileContent(file, allocator, io);
}

pub fn getFileContent(file: std.Io.File, allocator: std.mem.Allocator, io: std.Io) GetFileContentError![]const u8 {
    const size = try file.length(io);
    const buf = try allocator.alloc(u8, @intCast(size));
    var reader = file.reader(io, &.{});
    reader.interface.readSliceAll(buf) catch |err| switch (err) {
        std.Io.Reader.Error.ReadFailed => return reader.err.?,
        std.Io.Reader.Error.EndOfStream => unreachable,
    };
    return buf;
}

test "public sign keys iterator" {
    const key1 = "/H+xp947dDgJlSXBNIoI2IzHh9VLx9Vsgl8hdUb0104=";
    const key2 = "xn8Lk84Q1r5J3B5u5TIRutL6q2UWYfhw5Rdmjcj0tgw=";
    const key3 = "2knGd/uxY9voi7e97apaqom6LChIOmXaeFNhh94nH1g=";
    const key4 = "jPphqoGuFdcNg5ab/WRuIvMqXy9FTRRmFIBAYBwVWqA=";

    const host1 = "localhost:6767";
    const host2 = "localhost";
    const host3 = "dergdrive.pepa.dev";
    const host4 = "145.182.60.77:6969";

    const known_hosts_str = host1 ++ "=" ++ key1 ++ "\n" ++ host2 ++ "=" ++ key2 ++ "\n" ++ host3 ++ "=" ++ key3 ++ "\n" ++ host4 ++ "=" ++ key4 ++ "\n";

    var b64_encode_buf: [key1.len]u8 = undefined;
    const encoder = std.base64.standard.Encoder;

    var iter: PublicSignKeyIterator = .fromBuf(known_hosts_str, .{ .hostname = "localhost", .ip_addr = net.IpAddress.parse("127.0.0.1", 6767) catch unreachable, .hostname_strict = false });
    _ = encoder.encode(&b64_encode_buf, &iter.next().?.pub_key.toBytes());
    try std.testing.expectEqualStrings(key1, &b64_encode_buf);
    _ = encoder.encode(&b64_encode_buf, &iter.next().?.pub_key.toBytes());
    try std.testing.expectEqualStrings(key2, &b64_encode_buf);

    iter = .fromBuf(known_hosts_str, .{ .hostname = "localhost", .ip_addr = net.IpAddress.parse("127.0.0.1", 9999) catch unreachable, .hostname_strict = false });
    _ = encoder.encode(&b64_encode_buf, &iter.next().?.pub_key.toBytes());
    try std.testing.expectEqualStrings(key2, &b64_encode_buf);

    iter = .fromBuf(known_hosts_str, .{ .hostname = "dergdrive.pepa.dev", .ip_addr = net.IpAddress.parse("145.182.60.77", 6969) catch unreachable, .hostname_strict = false });
    _ = encoder.encode(&b64_encode_buf, &iter.next().?.pub_key.toBytes());
    try std.testing.expectEqualStrings(key3, &b64_encode_buf);
    _ = encoder.encode(&b64_encode_buf, &iter.next().?.pub_key.toBytes());
    try std.testing.expectEqualStrings(key4, &b64_encode_buf);

    iter = .fromBuf(known_hosts_str, .{ .hostname = "dergdrive.pepa.dev", .ip_addr = net.IpAddress.parse("145.182.60.77", 42069) catch unreachable, .hostname_strict = false });
    _ = encoder.encode(&b64_encode_buf, &iter.next().?.pub_key.toBytes());
    try std.testing.expectEqualStrings(key3, &b64_encode_buf);
    try std.testing.expectEqual(null, iter.next());
}

test "inline conf values" {
    const allocator = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();

    const io = std.testing.io;

    var emap = try std.testing.environ.createMap(arena.allocator());
    defer emap.deinit();

    var conf: Conf = .{ .emap = &emap };
    try conf.init(allocator);
    defer conf.deinit(allocator);

    var conf_file: ConfFile = .{ .nspace = .{ .nspace = .{ .config = .internal }, .pfix = .{ .config_internal = ".test" } }, .sub_path = "test.env" };
    try conf_file.init(conf, allocator);
    defer conf_file.deinit(allocator);

    try conf_file.setKeyValue("key1", "fooooo", arena.allocator(), io);
    try conf_file.setKeyValue("key3", "baar", arena.allocator(), io);
    try conf_file.setKeyValue("key2", "owo", arena.allocator(), io);
    try conf_file.setKeyValue("key3", "third_key", arena.allocator(), io);

    const val1 = (try conf_file.getKeyValue("key2", arena.allocator(), io)).?;
    const val2 = (try conf_file.getKeyValue("key1", arena.allocator(), io)).?;
    const val3 = (try conf_file.getKeyValue("key3", arena.allocator(), io)).?;

    try std.testing.expectEqualStrings("owo", val1);
    try std.testing.expectEqualStrings("fooooo", val2);
    try std.testing.expectEqualStrings("third_key", val3);
}
