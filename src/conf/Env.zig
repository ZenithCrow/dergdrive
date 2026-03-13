const std = @import("std");

const Conf = @import("Conf.zig");

const Env = @This();

pub const StoreEnvsError = std.mem.Allocator.Error || Conf.OpenOrCreateConfFileError || std.fs.File.WriteError;

pub const EnvValue = struct {
    val: []const u8,
    conf_file: Conf.ConfFile,
    runtime_modified: bool = false,
};

const ConfFileContext = struct {
    allocator: std.mem.Allocator,
    conf: Conf,

    pub fn hash(self: ConfFileContext, c: Conf.ConfFile) u64 {
        var key = c.getFullPath(self.conf, self.allocator) catch return 0;
        defer self.allocator.free(key);

        var h: std.hash.Wyhash = .init(0);

        while (key.len >= 64) : (key = key[64..]) {
            h.update(key[0..64]);
        }

        if (key.len > 0)
            h.update(key);

        return h.final();
    }

    pub fn eql(self: ConfFileContext, x: Conf.ConfFile, y: Conf.ConfFile) bool {
        const a = x.getFullPath(self.conf, self.allocator) catch return false;
        const b = y.getFullPath(self.conf, self.allocator) catch return false;
        return std.mem.eql(u8, a, b);
    }
};

pub var g_env: Env = undefined;

env_registry: std.StringArrayHashMap(EnvValue),
modified_envs: std.ArrayHashMap(Conf.ConfFile, void, ConfFileContext, true),
allocator: std.mem.Allocator,
conf: Conf,

pub fn initGlobal(conf: Conf, allocator: std.mem.Allocator) void {
    g_env = .{
        .conf = conf,
        .env_registry = .init(allocator),
        .modified_envs = .initContext(allocator, .{ .allocator = allocator, .conf = conf }),
        .allocator = allocator,
    };
}

pub fn loadEnvs(self: *Env) std.mem.Allocator.Error!void {
    for (Conf.conf_file_hierarchy) |env_conf_file| {
        //  TODO: distinguish between file not found and open/allocation errors
        var env_iter: Conf.KeyValueIterator = .init(self.conf.getConf(env_conf_file, self.allocator) catch continue);
        defer self.allocator.free(env_iter.line_iter.buffer);

        while (env_iter.next()) |kv_pair| {
            self.env_registry.put(try self.allocator.dupe(u8, kv_pair.key), .{
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
        var w = env_writers[self.modified_envs.getIndex(kv.value_ptr.conf_file) orelse continue];
        w.interface.print("{s}={s}\n", .{ kv.key_ptr.*, kv.value_ptr.val }) catch return w.err;
    }

    for (env_writers) |w| {
        w.interface.flush() catch return w.err;
    }
}

pub fn get(self: Env, key: []const u8) ?[]const u8 {
    if (self.env_registry.get(key)) |env_val| env_val.val else null;
}

pub fn set(self: *Env, key: []const u8, val: []const u8, conf_file: ?Conf.ConfFile) std.mem.Allocator.Error!void {
    const res = try self.env_registry.getOrPut(key);
    if (res.found_existing) {
        if (!std.mem.eql(u8, val, res.value_ptr.val)) {
            res.value_ptr.runtime_modified = true;
            res.value_ptr.val = val;
        }

        if (conf_file != null) {
            res.value_ptr.conf_file = conf_file;
            res.value_ptr.runtime_modified = true;
        }
    } else {
        res.value_ptr.* = .{
            .val = val,
            .conf_file = conf_file orelse Conf.conf_file_default,
            .runtime_modified = true,
        };
    }
}

//  TODO: tests!!!
