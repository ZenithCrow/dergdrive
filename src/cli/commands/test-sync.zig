const std = @import("std");
const dergdrive = @import("dergdrive");

const cli = dergdrive.cli;
const IncludeTree = dergdrive.client.track.IncludeTree;
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const FileReader = dergdrive.client.transmit.FileReader;
const SyncOp = dergdrive.client.track.SyncOp;

const include_rules_opt = @import("../options/include-rules.zig");
const root_dir_opt = @import("../options/root-dir.zig");
const vol_opt = @import("../options/vol.zig");

const log = std.log.scoped(.@"cli/commands/ls-include");

pub const command: cli.Command = .{
    .name = "test-sync",
    .usage = "test-sync [OPTIONS]",
    .desc = "(debug) Test syncing works as expected.",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            return testSync(args, emap, allocator, io) catch |err| switch (err) {
                cli.Command.ExecError.InvalidSyntax => @errorCast(err),
                cli.Command.ExecError.ReturnStatusFailure => @errorCast(err),
                else => blk: {
                    log.err("Command failed due to error: {t}.", .{err});
                    break :blk cli.Command.ExecError.ReturnStatusFailure;
                },
            };
        }
    }.execFn,
    .options = &.{
        vol_opt.option,
        include_rules_opt.option,
        root_dir_opt.option,
    },
};

fn testSync(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) !void {
    const ctx = try cli.command_exec.initBroadContext(args, emap, allocator, io);
    defer ctx.deinit(allocator);

    var param_vals: cli.command_exec.ParamContextValues = try .init(ctx, allocator, io);
    defer param_vals.deinit(allocator, io);
    // beyond this point, `root_path` and `include_rules_path` are not null

    var tree: IncludeTree = .init(param_vals.root_dir_iterable, param_vals.rule_text, allocator, io);
    defer tree.deinit();

    tree.buildMap() catch |err| {
        log.err("Failed to build include map due to error: {t}.", .{err});
        return error.BuildTreeFailed;
    };

    tree.sortMap();

    var file_record_map: FileRecordMap = .init(allocator);
    defer file_record_map.deinit();

    const generic_record: FileRecordMap.FileRecord = .{
        .blk_idx = 0,
        .length = 1,
        .offset = 0,
        .path = "",
        .pfix_id = 0,
        .tstamp = .{
            .mod_dev_id = 0,
            .mod_time = 0,
        },
    };

    for (&file_record_keys) |key| {
        try file_record_map.put(.borrowed(key), generic_record);
    }

    file_record_map.sort();

    try tree.iterateSortedFileRecords(&file_record_map, .{ 0, file_record_map.file_records.count() }, tree.rules, 1, "");

    var file_reader: FileReader = undefined;
    const sync_op: SyncOp = .{
        .excluded = false,
        .pull = .{ .deleted = false, .force = false, .new = true, .synced = true },
        .push = .{ .deleted = false, .force = false, .new = true, .synced = true },
    };

    const frmap_dir_iter: FileRecordMap.DirIterator = .{ .dir_range = .{ 0, file_record_map.file_records.count() }, .parent_path = "", .sorted_map = &file_record_map };

    try file_reader.syncDirApplyRules("", param_vals.root_dir_iterable, sync_op, frmap_dir_iter, tree, 1, allocator, io);
}

const file_record_keys = [_][]const u8{
    ".a/a",
    ".a/b",
    ".config/randomconfig.cfg",
    ".config/nvim",
    "code/cpp/myapp.cpp",
    "code/cpp/main",
    "code/zig/build",
    "code/zig/main",
    "documents/hschool/maturita",
};
