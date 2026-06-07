const std = @import("std");

const client = @import("client");
const options = client.cli.options;
const include_rules_opt = options.@"include-rules";
const vol_opt = options.vol;
const client_cli = client.cli;
const command_exec = client_cli.command_exec;
const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const IncludeTree = dergdrive.client.track.IncludeTree;
const FileRecordMap = dergdrive.client.track.FileRecordMap;
const FileReader = dergdrive.client.transmit.FileReader;
const SyncOp = dergdrive.client.track.SyncOp;
const unit_sync = dergdrive.client.track.unit_sync;
const root_dir_opt = dergdrive.cli.options.@"root-dir";

const log = std.log.scoped(.@"client/cli/commands/test-sync");

pub const command: cli.Command = .{
    .name = "test-sync",
    .usage = "test-sync [OPTIONS]",
    .desc = "(debug) Test syncing works as expected.",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            return testSync(args, emap, allocator, io) catch |err| switch (err) {
                cli.Command.ExecError.InvalidSyntax, cli.Command.ExecError.ReturnStatusFailure => |e| @errorCast(e),
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
    const ctx: command_exec.ParamContext = try .init(args, emap, allocator, io);
    defer ctx.deinit(allocator);

    var param_vals: command_exec.ParamContextValues = try .init(ctx, allocator, io);
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

    const generic_chunk: FileRecordMap.FileChunk = .{
        .blk_id = 0,
        .blk_offset = 0,
        .encoded_len = 1,
        .local_fi = .{
            .file_offset = 0,
            .real_len = 1,
        },
    };

    const generic_record: FileRecordMap.FileRecord = .{
        .length = 1,
        .num_blks = 1,
        .chunks = &.{generic_chunk},
        .opts = .{
            .deleted = false,
        },
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

    const sync_ctx: unit_sync.SyncUnitCtx = .{
        .allocator = allocator,
        .f_reader = &file_reader,
        .io = io,
    };

    try unit_sync.syncRootDirApplyRules(sync_ctx, param_vals.root_dir_iterable, sync_op, file_record_map, tree);
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
