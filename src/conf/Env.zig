const std = @import("std");

const Conf = @import("Conf.zig");

const Env = @This();

pub const StoreEnvsError = std.mem.Allocator.Error || Conf.OpenOrCreateConfFileError || std.fs.File.WriteError;

const log = std.log.scoped(.@"conf/env");

pub const EnvValue = struct {
    val: []const u8,
    conf_file: Conf.ConfFile,
    runtime_modified: bool = false,
};

const ConfFileContext = struct {
    allocator: std.mem.Allocator,
    conf: Conf,

    pub fn hash(self: ConfFileContext, c: Conf.ConfFile) u32 {
        var key = c.getFullPath(self.conf, self.allocator) catch return 0;
        defer self.allocator.free(key);

        var h: std.hash.Fnv1a_32 = .init();

        while (key.len >= 64) : (key = key[64..]) {
            h.update(key[0..64]);
        }

        if (key.len > 0)
            h.update(key);

        return h.final();
    }

    pub fn eql(self: ConfFileContext, x: Conf.ConfFile, y: Conf.ConfFile, _: usize) bool {
        const a = x.getFullPath(self.conf, self.allocator) catch return false;
        defer self.allocator.free(a);

        const b = y.getFullPath(self.conf, self.allocator) catch return false;
        defer self.allocator.free(b);

        return std.mem.eql(u8, a, b);
    }
};

pub var g_env: Env = undefined;

env_registry: std.StringArrayHashMap(EnvValue),
modified_envs: std.ArrayHashMap(Conf.ConfFile, void, ConfFileContext, true),
allocator: std.mem.Allocator,
conf: Conf,

pub fn init(conf: Conf, allocator: std.mem.Allocator) Env {
    return .{
        .conf = conf,
        .env_registry = .init(allocator),
        .modified_envs = .initContext(allocator, .{ .allocator = allocator, .conf = conf }),
        .allocator = allocator,
    };
}

pub fn initGlobal(conf: Conf, allocator: std.mem.Allocator) void {
    g_env = init(conf, allocator);
}

pub fn deinit(self: *Env) void {
    var iter = self.env_registry.iterator();
    while (iter.next()) |kv| {
        self.allocator.free(kv.key_ptr.*);
        self.allocator.free(kv.value_ptr.val);
    }

    self.env_registry.deinit();
    self.modified_envs.deinit();
}

pub fn loadEnvs(self: *Env) std.mem.Allocator.Error!void {
    for (self.conf.conf_file_hierarchy) |env_conf_file| {
        var env_iter: Conf.KeyValueIterator = .init(self.conf.getConf(env_conf_file, self.allocator) catch |err| switch (err) {
            Conf.GetConfError.OutOfMemory => return Conf.GetConfError.OutOfMemory,
            Conf.GetConfError.FileNotFound => continue,
            else => {
                log.warn("config file {f} could not be opened: {s}", .{ env_conf_file, @errorName(err) });
                continue;
            },
        });
        defer self.allocator.free(env_iter.line_iter.buffer);

        while (env_iter.next()) |kv_pair| {
            try self.env_registry.put(try self.allocator.dupe(u8, kv_pair.key), .{
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

    const env_writers = try self.allocator.alloc(std.fs.File.Writer, env_count);
    defer self.allocator.free(env_writers);

    for (self.modified_envs.keys(), 0..) |env, i| {
        const buf_part = write_buf_size / env_count;
        env_writers[i] = (try self.conf.openOrCreateConfFile(env, true, self.allocator)).writer(write_buf[buf_part * i .. buf_part * i + buf_part]);
    }
    defer {
        for (env_writers) |w| {
            w.file.close();
        }
    }

    var iter = self.env_registry.iterator();
    while (iter.next()) |kv| {
        const w: *std.fs.File.Writer = &env_writers[self.modified_envs.getIndex(kv.value_ptr.conf_file) orelse continue];
        w.interface.print("{s}={s}\n", .{ kv.key_ptr.*, kv.value_ptr.val }) catch return w.err.?;
    }

    for (env_writers) |*w| {
        w.interface.flush() catch return w.err.?;
    }
}

pub fn get(self: Env, key: []const u8) ?[]const u8 {
    return if (self.env_registry.get(key)) |env_val| env_val.val else null;
}

pub fn set(self: *Env, key: []const u8, val: []const u8, conf_file: ?Conf.ConfFile) std.mem.Allocator.Error!void {
    const res = try self.env_registry.getOrPut(key);
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
        try self.modified_envs.put(conf_file orelse self.conf.conf_file_default, {});
}

test "env config" {
    const allocator = std.testing.allocator;
    var conf: Conf = .{ .vol = "vol1" };
    var hierarchy = try allocator.dupe(Conf.ConfFile, conf.conf_file_hierarchy);
    defer allocator.free(hierarchy);

    const pfix: Conf.ConfPrefix = .{
        .global_linux = ".test/global",
        .internal = ".test/internal",
        .local_linux = ".test/local",
        .secret_linux = ".test/secret",
        .vol_local_linux = ".test/vol",
    };

    for (hierarchy) |*cf| {
        cf.nspace.pfix = pfix;
    }

    conf.conf_file_hierarchy = hierarchy;
    conf.conf_file_default.nspace.pfix = pfix;

    const weird_value: []const u8 = "hm = mmm - -ad -== 000";

    {
        var env: Env = .init(conf, allocator);
        defer env.deinit();

        try env.set("foo", "bar", null);
        try std.testing.expectEqualStrings("bar", env.get("foo").?);

        try env.set("override me", "base", null);
        try std.testing.expectEqualStrings("base", env.get("override me").?);

        try env.set("owo", "uwu", .{ .nspace = .{ .nspace = .global, .pfix = pfix }, .sub_path = "cowonfig.env" });
        try std.testing.expectEqualStrings("uwu", env.get("owo").?);

        try env.set("yay", weird_value, .{ .nspace = .{ .nspace = .local, .pfix = pfix }, .sub_path = "config" });
        try std.testing.expectEqualStrings(weird_value, env.get("yay").?);

        try env.set("override me", "overridden", null);
        try std.testing.expectEqualStrings("overridden", env.get("override me").?);

        try std.testing.expectEqual(2, env.modified_envs.count());

        try env.storeEnvs();
    }

    hierarchy = try allocator.realloc(hierarchy, hierarchy.len + 1);
    hierarchy[hierarchy.len - 1] = .{ .nspace = .{ .nspace = .global, .pfix = pfix }, .sub_path = "cowonfig.env" };

    conf.conf_file_hierarchy = hierarchy;

    {
        var env: Env = .init(conf, allocator);
        defer env.deinit();

        try env.loadEnvs();

        try std.testing.expectEqualStrings("bar", env.get("foo").?);
        try std.testing.expectEqualStrings("uwu", env.get("owo").?);
        try std.testing.expectEqualStrings(weird_value, env.get("yay").?);
        try std.testing.expectEqualStrings("overridden", env.get("override me").?);
    }
}
