const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const conf = dergdrive.conf;
const IncludeTree = dergdrive.client.track.IncludeTree;
const Env = conf.Env;

const include_rules_opt = @import("../options/include-rules.zig");
const root_dir_opt = @import("../options/root-dir.zig");
const vol_opt = @import("../options/vol.zig");

const log = std.log.scoped(.@"cli/commands/ls-include");

pub const command: cli.Command = .{
    .name = "ls-include",
    .usage = "ls-include [OPTIONS]",
    .desc = "Show a tree of included and/or ignored files in a volume",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, allocator: std.mem.Allocator) cli.Command.ExecError!void {
            return lsInclude(args, allocator) catch |err| switch (err) {
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
        mode_opt,
        hide_include_opt,
        hide_ignore_opt,
    },
};

const mode_opt: cli.Option = .{
    .long = "--mode",
    .short = 'm',
    .desc = "Selects the display mode of the tree. In 'include' mode it displays the include tree without traversing directory structure, whereas in 'traverse' mode it tracks all files across the whole directory structure.",
    .value = .{
        .eql_sign = true,
        .default = "traverse",
        .name = "MODE",
    },
};

const hide_include_opt: cli.Option = .{
    .long = "--hide-include",
    .short = 'h',
    .desc = "Don't show included files in traverse mode",
};

const hide_ignore_opt: cli.Option = .{
    .long = "--hide-ignore",
    .short = 'g',
    .desc = "Don't show ignored files in traverse mode",
};

const Mode = enum {
    include,
    traverse,
};

inline fn lsInclude(args: []const []const u8, allocator: std.mem.Allocator) !void {
    const ctx = try cli.command_exec.initBroadContext(args, allocator);
    defer cli.command_exec.deinitBroadContext();

    const root_path = if (ctx.root_path) |v| v else {
        log.err(cli.Option.opt_not_set_template, .{ "Root directory", root_dir_opt.root_dir_opt_name, root_dir_opt.option.long });
        return error.RootDirNotSet;
    };

    const include_rules_path = if (ctx.include_rules_path) |v| v else {
        log.err(cli.Option.opt_not_set_template, .{ "Include rules file", include_rules_opt.include_rules_opt_name, include_rules_opt.option.long });
        return error.IncludeRulesFileNotSet;
    };

    var root_dir = std.fs.openDirAbsolute(root_path, .{ .iterate = true }) catch |err| {
        log.err("Couldn't open root directory {s} due to error: {t}.", .{ root_path, err });
        return error.RootDirOpenFailed;
    };
    defer root_dir.close();

    const cwd = if (try Env.g_env.getWithCwd(include_rules_opt.include_rules_opt_name, false)) |val| val.cwd else std.fs.cwd();

    const rule_text = blk: {
        const rule_file = cwd.openFile(include_rules_path, .{}) catch |err| {
            log.err("Couldn't open include rules file {s} due to error: {t}.", .{ include_rules_path, err });
            return error.RuleFileOpenFailed;
        };
        defer rule_file.close();

        const size = try rule_file.getEndPos();

        var fr = rule_file.reader(&.{});
        break :blk try fr.interface.readAlloc(allocator, size);
    };
    defer allocator.free(rule_text);

    var tree: IncludeTree = .init(root_dir, rule_text, allocator);
    defer tree.deinit();
    tree.buildTree() catch |err| {
        log.err("Failed to build include tree due to error: {t}.", .{err});
        return error.BuildTreeFailed;
    };

    try tree.sort();

    var w_buf: [512]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&w_buf);
    const decorate = stdout_w.file.getOrEnableAnsiEscapeSupport();

    const vert_pipe: u16 = '\u{2502}';
    const bent_pipe: u16 = '\u{2514}';
    const hor_pipe: u16 = '\u{2500}';
    const triple_pipe: u16 = '\u{251c}';
    const space: u16 = '\u{0020}';

    const mode_str = cli.parser.getAssociatedValue(args, mode_opt.long, mode_opt.short, mode_opt.value.?.eql_sign) orelse mode_opt.value.?.default.?;
    switch (std.meta.stringToEnum(Mode, mode_str) orelse {
        log.err("Invalid mode: {s}.", .{mode_str});
        return error.InvalidMode;
    }) {
        .include => {
            cli.termfmt.printDecorated(&stdout_w.interface, decorate, &.{ .bold, .blue }, "{s}\n", .{root_path});

            var tree_iter = tree.iterateTree(allocator);
            defer tree_iter.deinit();

            while (try tree_iter.nextNodeLevel()) |res| { //: (_ = try tree_iter.nextNodeLevel()) {
                for (tree_iter.level_stack.items, 0..) |l, i| {
                    var l_iter = l;

                    if (i == tree_iter.level_stack.items.len - 1) {
                        try stdout_w.interface.print("{u}{u}{u} ", .{ if (l_iter.next() == null) bent_pipe else triple_pipe, hor_pipe, hor_pipe });

                        var item_text = switch (res.node) {
                            .dir => |dir| .{
                                dir.name,
                                &[_]cli.termfmt.Decoration{ .bold, if (IncludeTree.levelIsIgnore(res.level)) .red else .blue },
                            },
                            .file => |file| .{
                                file,
                                if (IncludeTree.levelIsIgnore(res.level)) &[_]cli.termfmt.Decoration{.red} else &[_]cli.termfmt.Decoration{},
                            },
                        };
                        if (i > 0) {
                            if (tree_iter.level_stack.items[i - 1].peekPrev()) |prev| {
                                item_text.@"0" = item_text.@"0"[prev.path().len + 1 ..];
                            }
                        }

                        cli.termfmt.printDecorated(&stdout_w.interface, decorate, item_text.@"1", "{s}\n", .{item_text.@"0"});
                    } else try stdout_w.interface.print("{u}   ", .{if (l_iter.next() == null) space else vert_pipe});
                }
            }
        },
        .traverse => {},
    }

    try stdout_w.interface.flush();
}
