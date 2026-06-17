const std = @import("std");

const Conf = @import("Conf.zig");

const Env = @This();

pub const StoreEnvsError = std.mem.Allocator.Error || Conf.OpenOrCreateConfFileError || std.Io.File.Writer.Error;

const log = std.log.scoped(.@"conf/Env");

pub const load_evs_err_notice = "Failed to load envs due to error: {t}.";

pub const EnvValue = struct {
    val: []const u8,
    conf_file: Conf.ConfFile,
    runtime_modified: bool = false,
};

const ConfFileContext = struct {
    allocator: std.mem.Allocator,
    conf: Conf,

    pub fn hash(self: ConfFileContext, c: Conf.ConfFile) u32 {
        const key = c.getFullPath(self.conf, self.allocator) catch return 0;
        defer self.allocator.free(key);

        var h: std.hash.Wyhash = .init(0);
        h.update(key);
        return @truncate(h.final());
    }

    pub fn eql(self: ConfFileContext, x: Conf.ConfFile, y: Conf.ConfFile, _: usize) bool {
        const a = x.getFullPath(self.conf, self.allocator) catch return false;
        defer self.allocator.free(a);

        const b = y.getFullPath(self.conf, self.allocator) catch return false;
        defer self.allocator.free(b);

        return std.mem.eql(u8, a, b);
    }
};

env_registry: std.array_hash_map.String(EnvValue),
modified_envs: std.array_hash_map.Custom(Conf.ConfFile, void, ConfFileContext, true),
modified_envs_ctx: ConfFileContext,
allocator: std.mem.Allocator,
io: std.Io,
conf: Conf,

pub fn init(conf: Conf, allocator: std.mem.Allocator, io: std.Io) Env {
    return .{
        .conf = conf,
        .env_registry = .empty,
        .modified_envs_ctx = .{ .allocator = allocator, .conf = conf },
        .modified_envs = .empty,
        .allocator = allocator,
        .io = io,
    };
}

pub fn deinit(self: *Env) void {
    var iter = self.env_registry.iterator();
    while (iter.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
        self.allocator.free(kv.value_ptr.val);
    }

    self.env_registry.deinit(self.allocator);
    self.modified_envs.deinit(self.allocator);
}

pub fn loadEnvs(self: *Env) std.mem.Allocator.Error!void {
    for (self.conf.conf_file_hierarchy) |env_conf_file| {
        var env_iter: Conf.KeyValueIterator = .init(self.conf.getConf(env_conf_file, self.allocator, self.io) catch |err| switch (err) {
            Conf.GetConfError.OutOfMemory => |e| return e,
            Conf.GetConfError.FileNotFound => continue,
            else => {
                log.warn("Config file {f} could not be opened due to error: {t}.", .{ env_conf_file, err });
                continue;
            },
        });
        defer self.allocator.free(env_iter.line_iter.buffer);

        while (env_iter.next()) |kv_pair| {
            try self.env_registry.put(self.allocator, try self.allocator.dupe(u8, kv_pair.key), .{
                .val = try self.allocator.dupe(u8, kv_pair.value),
                .conf_file = env_conf_file,
            });
        }
    }
}

pub fn storeEnvs(self: Env) StoreEnvsError!void {
    // split between all the writers
    const write_buf_size = 4096;
    var write_buf: [write_buf_size]u8 = undefined;

    const env_count = self.modified_envs.count();

    const env_writers = try self.allocator.alloc(std.Io.File.Writer, env_count);
    defer self.allocator.free(env_writers);

    for (self.modified_envs.keys(), 0..) |env, i| {
        const buf_part = write_buf_size / env_count;
        env_writers[i] = (try self.conf.openOrCreateConfFile(env, true, self.allocator, self.io)).writer(self.io, write_buf[buf_part * i .. buf_part * i + buf_part]);
    }
    defer {
        for (env_writers) |w| {
            w.file.close(self.io);
        }
    }

    var iter = self.env_registry.iterator();
    while (iter.next()) |kv| {
        const w: *std.Io.File.Writer = &env_writers[
            self.modified_envs.getIndexContext(kv.value_ptr.conf_file, self.modified_envs_ctx) orelse continue
        ];
        w.interface.print("{s}={s}\n", .{ kv.key_ptr.*, kv.value_ptr.val }) catch return w.err.?;
    }

    for (env_writers) |*w| {
        w.interface.flush() catch return w.err.?;
    }
}

pub fn get(self: Env, key: []const u8) ?[]const u8 {
    return if (self.env_registry.get(key)) |env_val| env_val.val else null;
}

pub const GetWithCwdResultError = std.mem.Allocator.Error || std.Io.File.OpenError;

pub const GetWithCwdResult = struct {
    val: []const u8,
    cwd: std.Io.Dir,
};

pub fn getWithCwd(self: Env, key: []const u8, iterate: bool, io: std.Io) GetWithCwdResultError!?GetWithCwdResult {
    if (self.env_registry.get(key)) |env_val| {
        const full_path = try env_val.conf_file.getFullPath(self.conf, self.allocator);
        defer self.allocator.free(full_path);

        const last_slash = std.mem.lastIndexOfScalar(u8, full_path, '/');

        return .{
            .val = env_val.val,
            .cwd = if (last_slash) |l| try std.Io.Dir.cwd().openDir(io, full_path[0..l], .{ .iterate = iterate }) else std.Io.Dir.cwd(),
        };
    } else return null;
}

pub fn set(self: *Env, key: []const u8, val: []const u8, conf_file: ?Conf.ConfFile) std.mem.Allocator.Error!void {
    const res = try self.env_registry.getOrPut(self.allocator, key);
    if (res.found_existing) {
        if (!std.mem.eql(u8, val, res.value_ptr.val)) {
            res.value_ptr.runtime_modified = true;
            self.allocator.free(res.value_ptr.val);
            res.value_ptr.val = try self.allocator.dupe(u8, val);
        }

        if (conf_file) |cf| {
            res.value_ptr.conf_file = cf;
            res.value_ptr.runtime_modified = true;
        }
    } else {
        res.value_ptr.* = .{
            .val = try self.allocator.dupe(u8, val),
            .conf_file = conf_file orelse self.conf.conf_file_default,
            .runtime_modified = true,
        };

        res.key_ptr.* = try self.allocator.dupe(u8, key);
    }

    if (res.value_ptr.runtime_modified)
        try self.modified_envs.putContext(self.allocator, conf_file orelse self.conf.conf_file_default, {}, self.modified_envs_ctx);
}

test "client env config" {
    const dergdrive = @import("dergdrive");
    const client = dergdrive.client;

    const allocator = std.testing.allocator;
    var arena_alloc: std.heap.ArenaAllocator = .init(allocator);
    defer arena_alloc.deinit();
    const arena = arena_alloc.allocator();

    const io = std.testing.io;

    var emap = try std.testing.environ.createMap(arena);
    defer emap.deinit();

    var conf: client.conf.Conf = .init("vol1", &emap);
    var hierarchy = try allocator.dupe(Conf.ConfFile, conf.root_conf.conf_file_hierarchy);
    defer allocator.free(hierarchy);

    const pfix: Conf.ConfPrefix = .{
        .config_global_linux = ".test/global",
        .config_internal = ".test/internal",
        .config_user_linux = ".test/local",
        .pers_user_secret_linux = ".test/secret",
        .config_vol_linux = ".test/{vol}",
        .pers_vol_secret_linux = ".test/{vol}/secret",
    };

    for (hierarchy) |*cf| {
        cf.nspace.pfix = pfix;
    }

    conf.root_conf.conf_file_hierarchy = hierarchy;
    conf.root_conf.conf_file_default.nspace.pfix = pfix;

    const weird_value: []const u8 = "hm = mmm - -ad -== 000";

    {
        var env: Env = .init(conf.root_conf, allocator, io);
        defer env.deinit();

        try env.set("foo", "bar", null);
        try std.testing.expectEqualStrings("bar", env.get("foo").?);

        try env.set("override me", "base", null);
        try std.testing.expectEqualStrings("base", env.get("override me").?);

        try env.set("owo", "uwu", .{ .nspace = .{ .nspace = .{ .config = .global }, .pfix = pfix }, .sub_path = "cowonfig.env" });
        try std.testing.expectEqualStrings("uwu", env.get("owo").?);

        try env.set("yay", weird_value, .{ .nspace = .{ .nspace = .{ .config = .user }, .pfix = pfix }, .sub_path = "config" });
        try std.testing.expectEqualStrings(weird_value, env.get("yay").?);

        try env.set("override me", "overridden", null);
        try std.testing.expectEqualStrings("overridden", env.get("override me").?);

        try std.testing.expectEqual(2, env.modified_envs.count());

        try env.storeEnvs();
    }

    hierarchy = try allocator.realloc(hierarchy, hierarchy.len + 1);
    hierarchy[hierarchy.len - 1] = .{ .nspace = .{ .nspace = .{ .config = .global }, .pfix = pfix }, .sub_path = "cowonfig.env" };

    conf.root_conf.conf_file_hierarchy = hierarchy;

    {
        var env: Env = .init(conf.root_conf, allocator, io);
        defer env.deinit();

        try env.loadEnvs();

        try std.testing.expectEqualStrings("bar", env.get("foo").?);
        try std.testing.expectEqualStrings("uwu", env.get("owo").?);
        try std.testing.expectEqualStrings(weird_value, env.get("yay").?);
        try std.testing.expectEqualStrings("overridden", env.get("override me").?);
    }
}
