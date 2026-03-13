const std = @import("std");
const builtin = @import("builtin");

const Conf = @This();

const proj_name: []const u8 = "dergdrive";

pub const GetFileContentError = std.fs.File.StatError || std.mem.Allocator.Error || std.fs.File.ReadError;
pub const GetFileContentFromPathError = OpenOrCreateConfFileError;
pub const OpenOrCreateConfFileError = std.fs.Dir.MakeError || std.fs.Dir.OpenError || std.fs.Dir.StatError || std.fs.File.OpenError || std.mem.Allocator.Error || std.fs.File.ChmodError;
pub const WriteConfFileError = OpenOrCreateConfFileError || std.fs.File.WriteError;

const global_linux: []const u8 = "/etc/" ++ proj_name;
const local_linux: []const u8 = "~/.config/" ++ proj_name;
const vol_local_linux: []const u8 = local_linux ++ "/{vol}";
const secret_linux: []const u8 = local_linux ++ "/secret";
const internal: []const u8 = ".";

pub const LocNamespace = enum {
    global,
    local,
    vol_local,
    internal,
    secret,

    pub fn getRoot(namespace: LocNamespace) []const u8 {
        return switch (builtin.os.tag) {
            .linux => switch (namespace) {
                .global => global_linux,
                .local => local_linux,
                .vol_local => vol_local_linux,
                .internal => internal,
                .secret => secret_linux,
            },
            else => @compileError("implement this for your os if you want it so bad"),
        };
    }
};

pub const ConfFile = struct {
    nspace: LocNamespace,
    sub_path: []const u8,
    always_create: bool,

    pub fn getFullPath(self: ConfFile, conf: Conf, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        const root_path = self.nspace.getRoot();
        const expanded = try conf.expand(root_path, allocator);
        defer allocator.free(expanded);
        return std.mem.join(allocator, "/", &.{ expanded, self.sub_path });
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

const config_filename = "config";
pub const conf_file_default: ConfFile = .{ .nspace = .local, .sub_path = config_filename, .always_create = true };
pub const conf_file_hierarchy: []const ConfFile = switch (builtin.os.tag) {
    .linux => &.{
        .{ .nspace = .global, .sub_path = config_filename, .always_create = false },
        conf_file_default,
        .{ .nspace = .vol_local, .sub_path = config_filename, .always_create = false },
    },
    else => @compileError("implement this for your os if you want it so bad"),
};

pub var g_conf: Conf = undefined;

vol: []const u8,

pub fn initGlobal(vol: []const u8) Conf {
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
    return file.readToEndAlloc(allocator, std.math.maxInt(usize));
}

pub fn getConf(self: Conf, conf_file: ConfFile, allocator: std.mem.Allocator) GetFileContentFromPathError![]const u8 {
    return if (conf_file.always_create) self.openOrCreateConfFile(conf_file, false, allocator) else {
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

    if (conf_file.nspace == .secret)
        try file.chmod(0o600);

    return file;
}

pub fn writeConfFile(self: Conf, conf_file: ConfFile, truncate: bool, data: []const u8, allocator: std.mem.Allocator) WriteConfFileError!void {
    const file = try self.openOrCreateConfFile(conf_file, truncate, allocator);
    errdefer file.close();

    var writer = file.writer(&.{});
    return writer.interface.writeAll(data) catch writer.err;
}

pub fn get(self: Conf, env_file: ConfFile, key: []const u8, allocator: std.mem.Allocator) GetFileContentFromPathError!?[]const u8 {
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

pub fn set(self: Conf, env_file: ConfFile, key: []const u8, value: []const u8, allocator: std.mem.Allocator) (GetFileContentFromPathError || WriteConfFileError)!void {
    var iter: KeyValueIterator = .init(try self.getConf(env_file, allocator));
    defer allocator.free(iter.line_iter.buffer);

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

    var buf: []u8 = @constCast(iter.line_iter.buffer);

    if (insert) {
        const tail_index = index + key_len + val_len + 1;
        const len_diff: isize = @bitCast(value.len -% val_len);
        const old_len = buf.len;
        const new_len: usize = @bitCast(@as(isize, @bitCast(buf.len)) + len_diff);

        // move before resizing if the new length is smaller to avoid clipping
        if (new_len < buf.len)
            @memmove(buf[@bitCast(@as(isize, @bitCast(tail_index)) + len_diff)..new_len], buf[tail_index..]);

        buf = try allocator.realloc(buf, new_len);

        if (new_len >= old_len)
            @memmove(buf[@bitCast(@as(isize, @bitCast(tail_index)) + len_diff)..], buf[tail_index..old_len]);

        const value_index = index + key_len + 1;
        @memcpy(buf[value_index .. value_index + value.len], value);
    } else {
        var old_len = buf.len;
        const line_break = old_len != 0 and buf[old_len - 1] == '\n' or old_len == 0;

        if (!line_break)
            old_len += 1;

        const new_len = old_len + key.len + value.len + 1;
        buf = try allocator.realloc(buf, new_len);

        if (!line_break)
            buf[old_len - 1] = '\n';

        @memcpy(buf[old_len .. old_len + key.len], key);
        buf[old_len + key.len] = kv_delim;
        @memcpy(buf[old_len + key.len + 1 ..], value);
    }

    iter.line_iter.buffer = buf;
    try self.writeConfFile(env_file, false, buf, allocator);
}

test "config key value pairs" {
    const allocator = std.testing.allocator;
    const c: Conf = .{ .vol = "" };

    const test_file: ConfFile = .{
        .nspace = .internal,
        .sub_path = "test.env",
        .always_create = true,
    };

    try c.set(test_file, "key1", "owo", allocator);
    try c.set(test_file, "key2", "bar", allocator);
    try c.set(test_file, "key1", "foooo", allocator);

    {
        const val1 = try c.get(test_file, "key1", allocator);
        defer allocator.free(val1.?);
        try std.testing.expectEqualStrings(val1.?, "foooo");
    }

    try c.set(test_file, "key1", "owo", allocator);

    {
        const val1 = try c.get(test_file, "key1", allocator);
        defer allocator.free(val1.?);
        try std.testing.expectEqualStrings(val1.?, "owo");
    }
}
