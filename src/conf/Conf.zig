const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
const Conf = @This();

pub const proj_name: []const u8 = dergdrive.cli.command_exec.prog_name;

pub const GetFileContentError = std.fs.File.StatError || std.mem.Allocator.Error || std.fs.File.ReadError;
pub const GetFileContentFromPathError = GetFileContentError || std.fs.File.OpenError;
pub const OpenOrCreateConfFileError = std.fs.Dir.MakeError || std.fs.Dir.OpenError || std.fs.Dir.StatError || std.fs.File.OpenError || std.mem.Allocator.Error || std.fs.File.ChmodError;
pub const WriteConfFileError = OpenOrCreateConfFileError || std.fs.File.WriteError;
pub const GetConfError = GetFileContentError || GetFileContentFromPathError || OpenOrCreateConfFileError;
pub const SetError = GetFileContentError || OpenOrCreateConfFileError || std.fs.File.SeekError || std.fs.File.SetEndPosError || std.fs.File.WriteError;

const pers_internal: []const u8 = "./share";
const cache_internal: []const u8 = "./cache";
const config_internal: []const u8 = "./config";

const config_global_linux: []const u8 = "/etc/" ++ proj_name;
const config_local_linux: []const u8 = "~/.config/" ++ proj_name;
const config_vol_local_linux: []const u8 = config_local_linux ++ "/{vol}";
const config_secret_linux: []const u8 = config_local_linux ++ "/secret";
const config_vol_secret_linux: []const u8 = config_vol_local_linux ++ "/secret";
const cache_global_linux: []const u8 = "/var/cache/" ++ proj_name;
const cache_local_linux: []const u8 = "~/.cache/" ++ proj_name;
const cache_vol_local_linux: []const u8 = cache_local_linux ++ "/{vol}";
const pers_global_linux: []const u8 = "/usr/share/" ++ proj_name;
const pers_local_linux: []const u8 = "~/.local/share/" ++ proj_name;
const pers_vol_local_linux: []const u8 = pers_local_linux ++ "/{vol}";

const config_global_windows: []const u8 = pers_global_windows ++ "\\config";
const config_local_windows: []const u8 = pers_local_windows ++ "\\config";
const config_vol_local_windows: []const u8 = config_vol_local_windows ++ "\\{vol}";
const config_secret_windows: []const u8 = config_local_windows ++ "\\secret";
const config_vol_secret_windows: []const u8 = config_vol_local_windows ++ "\\secret";
const cache_global_windows: []const u8 = config_global_windows ++ "\\cache";
const cache_local_windows: []const u8 = "%TEMP%\\" ++ proj_name;
const cache_vol_local_windows: []const u8 = cache_local_windows ++ "\\{vol}";
const pers_global_windows: []const u8 = "%PROGRAMDATA%\\" ++ proj_name;
const pers_local_windows: []const u8 = "%APPDATALOCAL%\\" ++ proj_name;
const pers_vol_local_windows: []const u8 = pers_local_windows ++ "\\{vol}";

pub const ConfPrefix = struct {
    config_global_linux: []const u8 = config_global_linux,
    config_local_linux: []const u8 = config_local_linux,
    config_vol_local_linux: []const u8 = config_vol_local_linux,
    config_secret_linux: []const u8 = config_secret_linux,
    config_vol_secret_linux: []const u8 = config_vol_secret_linux,
    config_internal: []const u8 = config_internal,
    cache_global_linux: []const u8 = cache_global_linux,
    cache_local_linux: []const u8 = cache_local_linux,
    cache_vol_local_linux: []const u8 = cache_vol_local_linux,
    cache_internal: []const u8 = cache_internal,
    pers_global_linux: []const u8 = pers_global_linux,
    pers_local_linux: []const u8 = pers_local_linux,
    pers_vol_local_linux: []const u8 = pers_vol_local_linux,
    pers_internal: []const u8 = pers_internal,
};

pub const Nspace = enum {
    global,
    local,
    vol_local,
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
                    .local => self.pfix.config_local_linux,
                    .vol_local => self.pfix.config_vol_local_linux,
                    .internal => self.pfix.config_internal,
                    .secret => self.pfix.config_secret_linux,
                    .vol_secret => self.pfix.config_vol_secret_linux,
                },
                .cache => |nspace| switch (nspace) {
                    .global => self.pfix.cache_global_linux,
                    .local => self.pfix.cache_local_linux,
                    .vol_local => self.pfix.cache_vol_local_linux,
                    .internal => self.pfix.cache_internal,
                    else => @panic("namespace not supported for cache"),
                },
                .pers => |nspace| switch (nspace) {
                    .global => self.pfix.pers_global_linux,
                    .local => self.pfix.pers_local_linux,
                    .vol_local => self.pfix.pers_vol_local_linux,
                    .internal => self.pfix.pers_internal,
                    else => @panic("namespace not supported for persistent storage"),
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

    pub fn getFullPath(self: ConfFile, conf: Conf, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const root_path = self.nspace.getRoot();
        const expanded = try conf.expand(root_path, allocator);
        defer allocator.free(expanded);
        return std.mem.join(allocator, "/", &.{ expanded, self.sub_path });
    }

    pub fn format(
        self: @This(),
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        try writer.print("{s}/{s}", .{ self.nspace.getRoot(), self.sub_path });
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
        return .{ .line_iter = std.mem.splitAny(u8, enf_file_buf, "\r\n") };
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

const config_filename = "config.ini";
const g_conf_file_default: ConfFile = .{ .nspace = .from(.{ .config = .local }), .sub_path = config_filename, .always_create = true };
const g_conf_file_hierarchy: []const ConfFile = switch (builtin.os.tag) {
    .linux => &.{
        .{ .nspace = .from(.{ .config = .global }), .sub_path = config_filename, .always_create = false },
        g_conf_file_default,
        .{ .nspace = .from(.{ .config = .vol_local }), .sub_path = config_filename, .always_create = false },
    },
    else => @compileError("implement this for your os if you want it so bad"),
};

const g_mfest_cache: ConfFile = .{ .nspace = .from(.{ .cache = .vol_local }), .sub_path = "manifest" };
const g_oride_prefixes: ConfFile = .{ .nspace = .from(.{ .config = .vol_local }), .sub_path = "prefix-overrides.ini" };

pub var g_conf: Conf = undefined;

conf_file_default: ConfFile = g_conf_file_default,
conf_file_hierarchy: []const ConfFile = g_conf_file_hierarchy,
mfest_cache: ConfFile = g_mfest_cache,
oride_prefixes: ConfFile = g_oride_prefixes,

vol: []const u8,

pub fn initGlobal(vol: []const u8) void {
    g_conf = .{ .vol = vol };
}

pub fn expand(self: Conf, path: []const u8, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    const home_expanded = blk: switch (builtin.os.tag) {
        .linux => {
            if (path.len > 0 and path[0] == '~') {
                var home = std.posix.getenv("HOME");
                if (home == null)
                    home = std.posix.getenv("USERPROFILE");

                if (home == null)
                    std.debug.panic("user home directory could not be inquired", .{});

                const slices: []const []const u8 = if (path.len > 2 and path[1] == '/') &.{ home.?, path[2..] } else &.{home.?};
                break :blk try std.mem.join(allocator, "/", slices);
            }

            break :blk try allocator.dupe(u8, path);
        },
        else => try allocator.dupe(u8, path),
    };
    defer allocator.free(home_expanded);

    return std.mem.replaceOwned(u8, allocator, home_expanded, "{vol}", self.vol);
}

fn getFileContentFromPath(path: []const u8, allocator: std.mem.Allocator) GetFileContentFromPathError![]const u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    return getFileContent(file, allocator);
}

fn getFileContent(file: std.fs.File, allocator: std.mem.Allocator) GetFileContentError![]const u8 {
    var reader = file.reader(&.{});
    return reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        std.Io.Reader.ShortError.ReadFailed => return reader.err.?,
        std.Io.Reader.LimitedAllocError.StreamTooLong => unreachable,
        else => return std.mem.Allocator.Error.OutOfMemory,
    };
}

pub fn getConf(self: Conf, conf_file: ConfFile, allocator: std.mem.Allocator) GetConfError![]const u8 {
    return if (conf_file.always_create) getFileContent(try self.openOrCreateConfFile(conf_file, false, allocator), allocator) else {
        const full_path = try conf_file.getFullPath(self, allocator);
        defer allocator.free(full_path);

        return getFileContentFromPath(full_path, allocator);
    };
}

pub fn openOrCreateConfFile(self: Conf, conf_file: ConfFile, truncate: bool, allocator: std.mem.Allocator) OpenOrCreateConfFileError!std.fs.File {
    const full_path = try conf_file.getFullPath(self, allocator);
    defer allocator.free(full_path);

    const last_slash = std.mem.lastIndexOfScalar(u8, full_path, '/');
    const dir_path = full_path[0 .. last_slash orelse 0];

    const file_delim = if (last_slash) |pos| pos + 1 else 0;
    const file_path = full_path[file_delim..];

    var dir = try std.fs.cwd().makeOpenPath(dir_path, .{});
    errdefer dir.close();

    const file = try dir.createFile(file_path, .{ .read = true, .truncate = truncate });
    errdefer file.close();

    switch (conf_file.nspace.nspace) {
        .cache, .config, .pers => |nspace| if (nspace == .secret) try file.chmod(0o600),
    }

    return file;
}

pub fn writeConfFile(self: Conf, conf_file: ConfFile, truncate: bool, data: []const u8, allocator: std.mem.Allocator) WriteConfFileError!void {
    const file = try self.openOrCreateConfFile(conf_file, truncate, allocator);
    errdefer file.close();

    var writer = file.writer(&.{});
    return writer.interface.writeAll(data) catch writer.err.?;
}

pub fn get(self: Conf, env_file: ConfFile, key: []const u8, allocator: std.mem.Allocator) GetConfError!?[]const u8 {
    const iter: KeyValueIterator = .init(try self.getConf(env_file, allocator));
    defer allocator.free(iter.line_iter.buffer);
    return if (getFromIter(iter, key)) |value| try allocator.dupe(u8, value) else null;
}

pub fn getFromIter(kv_iter: KeyValueIterator, key: []const u8) ?[]const u8 {
    var iter_cpy = kv_iter;
    iter_cpy.line_iter.index = 0;
    return while (iter_cpy.next()) |entry| {
        if (std.mem.eql(u8, entry.key, key))
            break entry.value;
    } else null;
}

pub fn set(self: Conf, env_file: ConfFile, key: []const u8, value: []const u8, allocator: std.mem.Allocator) SetError!void {
    const file = try self.openOrCreateConfFile(env_file, false, allocator);
    defer file.close();
    const buf = try getFileContent(file, allocator);
    defer allocator.free(buf);
    var iter: KeyValueIterator = .init(buf);

    var writer = file.writer(&.{});

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
            break true;
        }
    } else false;

    if (insert) {
        const tail_index = index + key_len + val_len + 1;
        const len_diff: isize = @bitCast(value.len -% val_len);
        const new_len: usize = @bitCast(@as(isize, @bitCast(buf.len)) + len_diff);

        writer.seekTo(index + key_len + 1) catch return writer.seek_err.?;
        writer.interface.writeAll(value) catch return writer.err.?;
        writer.interface.writeAll(buf[tail_index..]) catch return writer.err.?;
        try file.setEndPos(new_len);
    } else {
        const end = try file.getEndPos();
        const line_break = buf.len > 0 and buf[buf.len - 1] == '\n';

        writer.seekTo(end) catch return writer.seek_err.?;
        if (!line_break)
            writer.interface.writeByte('\n') catch return writer.err.?;

        writer.interface.print("{s}={s}\n", .{ key, value }) catch return writer.err.?;
    }
}

test "config key value pairs" {
    const allocator = std.testing.allocator;
    const c: Conf = .{ .vol = "" };

    const test_file: ConfFile = .{
        .nspace = .from(.{ .config = .internal }),
        .sub_path = ".test/test.env",
        .always_create = true,
    };

    try c.set(test_file, "key1", "owo", allocator);
    try c.set(test_file, "key2", "bar", allocator);
    try c.set(test_file, "key1", "foooo", allocator);

    {
        const val1 = (try c.get(test_file, "key1", allocator)).?;
        defer allocator.free(val1);
        try std.testing.expectEqualStrings("foooo", val1);
    }

    try c.set(test_file, "key1", "owo", allocator);

    {
        const val1 = (try c.get(test_file, "key1", allocator)).?;
        defer allocator.free(val1);
        try std.testing.expectEqualStrings("owo", val1);
    }

    {
        const val2 = (try c.get(test_file, "key2", allocator)).?;
        defer allocator.free(val2);
        try std.testing.expectEqualStrings("bar", val2);
    }
}
