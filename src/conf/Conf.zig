const std = @import("std");
const builtin = @import("builtin");

const dergdrive = @import("dergdrive");
pub const proj_name: []const u8 = dergdrive.cli.command_exec.prog_name;

const Conf = @This();

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

pub const config_filename = "config.ini";
pub const g_conf_file_default: ConfFile = .{ .nspace = .from(.{ .config = .user }), .sub_path = config_filename, .always_create = true };
pub const g_conf_file_hierarchy: []const ConfFile = switch (builtin.os.tag) {
    .linux => &.{
        .{ .nspace = .from(.{ .config = .internal }), .sub_path = config_filename, .always_create = false },
        .{ .nspace = .from(.{ .config = .global }), .sub_path = config_filename, .always_create = false },
        g_conf_file_default,
    },
    else => @compileError("implement this for your os if you want it so bad"),
};

conf_file_default: ConfFile = g_conf_file_default,
conf_file_hierarchy: []const ConfFile = g_conf_file_hierarchy,
emap: *const std.process.Environ.Map,
// default value for compatiblity with server implementation (client should always override it)
vol: []const u8 = "snudoo",

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
            }

            break :blk start_str;
        },
        else => path,
    };
    defer if (var_exp_alloced) gpa.free(var_exp);

    return std.mem.replaceOwned(u8, gpa, var_exp, "{vol}", self.vol);
}

fn getFileContentFromPath(path: []const u8, allocator: std.mem.Allocator, io: std.Io) GetFileContentFromPathError![]const u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    return getFileContent(file, allocator, io);
}

fn getFileContent(file: std.Io.File, allocator: std.mem.Allocator, io: std.Io) GetFileContentError![]const u8 {
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .unlimited) catch |err| switch (err) {
        std.Io.Reader.ShortError.ReadFailed => return reader.err.?,
        std.Io.Reader.LimitedAllocError.StreamTooLong => unreachable,
        else => return std.mem.Allocator.Error.OutOfMemory,
    };
}

pub fn getConf(self: Conf, conf_file: ConfFile, allocator: std.mem.Allocator, io: std.Io) GetConfError![]const u8 {
    return if (conf_file.always_create) getFileContent(try self.openOrCreateConfFile(conf_file, false, allocator, io), allocator, io) else {
        const full_path = try conf_file.getFullPath(self, allocator);
        defer allocator.free(full_path);

        return getFileContentFromPath(full_path, allocator, io);
    };
}

pub fn openOrCreateConfFile(self: Conf, conf_file: ConfFile, truncate: bool, allocator: std.mem.Allocator, io: std.Io) OpenOrCreateConfFileError!std.Io.File {
    const full_path = try conf_file.getFullPath(self, allocator);
    defer allocator.free(full_path);

    const last_slash = std.mem.lastIndexOfScalar(u8, full_path, '/');
    const dir_path = full_path[0 .. last_slash orelse 0];

    const file_delim = if (last_slash) |pos| pos + 1 else 0;
    const file_path = full_path[file_delim..];

    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{});
    errdefer dir.close(io);

    const file = try dir.createFile(io, file_path, .{ .read = true, .truncate = truncate });
    errdefer file.close(io);

    switch (conf_file.nspace.nspace) {
        .cache, .config, .pers => |nspace| if (nspace == .secret) try file.setPermissions(io, .fromMode(0o600)),
    }

    return file;
}

pub fn writeConfFile(self: Conf, conf_file: ConfFile, truncate: bool, data: []const u8, allocator: std.mem.Allocator, io: std.Io) WriteConfFileError!void {
    const file = try self.openOrCreateConfFile(conf_file, truncate, allocator, io);
    errdefer file.close(io);

    var writer = file.writer(io, &.{});
    return writer.interface.writeAll(data) catch writer.err.?;
}

/// use env layer instead of this access
pub fn get(self: Conf, env_file: ConfFile, key: []const u8, allocator: std.mem.Allocator, io: std.Io) GetConfError!?[]const u8 {
    const iter: KeyValueIterator = .init(try self.getConf(env_file, allocator, io));
    defer allocator.free(iter.line_iter.buffer);
    return if (getFromIter(iter, key)) |value| try allocator.dupe(u8, value) else null;
}

/// use env layer instead of this access
pub fn getFromIter(kv_iter: KeyValueIterator, key: []const u8) ?[]const u8 {
    var iter_cpy = kv_iter;
    iter_cpy.line_iter.index = 0;
    return while (iter_cpy.next()) |entry| {
        if (std.mem.eql(u8, entry.key, key))
            break entry.value;
    } else null;
}

/// use env layer instead of this accesss
pub fn set(self: Conf, env_file: ConfFile, key: []const u8, value: []const u8, allocator: std.mem.Allocator, io: std.Io) SetError!void {
    const file = try self.openOrCreateConfFile(env_file, false, allocator, io);
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
        try file.setLength(io, new_len);
    } else {
        const end = try file.length(io);
        const line_break = buf.len > 0 and buf[buf.len - 1] == '\n';

        writer.seekTo(end) catch return writer.seek_err.?;
        if (!line_break)
            writer.interface.writeByte('\n') catch return writer.err.?;

        writer.interface.print("{s}={s}\n", .{ key, value }) catch return writer.err.?;
    }
}
