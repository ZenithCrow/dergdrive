const std = @import("std");

const client = @import("client");
const options = client.cli.options;
const include_rules_opt = options.@"include-rules";
const vol_opt = options.vol;
const client_cli = client.cli;
const command_exec = client_cli.command_exec;
const service = client_cli.service;
const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const conf = dergdrive.conf;
const IncludeTree = dergdrive.client.track.IncludeTree;
const Env = conf.Env;
const root_dir_opt = dergdrive.cli.options.@"root-dir";

const log = std.log.scoped(.@"client/cli/commands/ls-include");

pub const command: cli.Command = .{
    .name = "ls-include",
    .usage = "ls-include [OPTIONS]",
    .desc = "Show a tree of included and/or ignored files in a volume",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            return lsInclude(args, emap, allocator, io) catch |err| switch (err) {
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
        only_include_opt,
        only_ignore_opt,
        list_ignore_opt,
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

const only_include_opt: cli.Option = .{
    .long = "--only-included",
    .short = 'c',
    .desc = "Only show included files in traverse mode",
};

const only_ignore_opt: cli.Option = .{
    .long = "--only-ignored",
    .short = 'g',
    .desc = "Only show ignored files in traverse mode",
};

const list_ignore_opt: cli.Option = .{
    .long = "--travs-ignored",
    .short = 't',
    .desc = "Traverse and list directories whose contents are all ignored",
};

const Mode = enum {
    include,
    traverse,
};

inline fn lsInclude(args: []const []const u8, emap: *const std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) !void {
    const ctx: service.ParamContext = try .init(args, emap, allocator, io);
    defer ctx.deinit(allocator);

    var param_vals: service.ParamContextValues = try .init(ctx, allocator, io);
    defer param_vals.deinit(allocator, io);
    // beyond this point, `root_path` and `include_rules_path` are not null

    var tree: IncludeTree = .init(param_vals.root_dir_iterable, param_vals.rule_text, allocator, io);
    defer tree.deinit();

    var w_buf: [512]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writerStreaming(io, &w_buf);
    const decorate = try stdout_w.file.supportsAnsiEscapeCodes(io);

    try cli.termfmt.printDecorated(&stdout_w.interface, decorate, &.{ .bold, .blue }, "{s}\n", .{ctx.root_path.?});

    const vert_pipe = "\u{2502}";
    const bent_pipe = "\u{2514}";
    const hor_pipe = "\u{2500}";
    const triple_pipe = "\u{251c}";
    const space = "\u{0020}";

    const mode_str = cli.parser.getAssociatedValue(args, mode_opt.long, mode_opt.short, mode_opt.value.?.eql_sign) orelse mode_opt.value.?.default.?;
    sw: switch (std.meta.stringToEnum(Mode, mode_str) orelse {
        log.err("Invalid mode: {s}.", .{mode_str});
        return error.InvalidMode;
    }) {
        //  TODO: use the map implementation (the same as in `traverse`)
        .include => {
            tree.buildTree() catch |err| {
                log.err("Failed to build include tree due to error: {t}.", .{err});
                return error.BuildTreeFailed;
            };

            try tree.sortHumanly();

            var tree_iter = tree.iterateTree(allocator);
            defer tree_iter.deinit();

            while (try tree_iter.nextNodeLevel()) |res| {
                for (tree_iter.level_stack.items, 0..) |l, i| {
                    var l_iter = l;

                    if (i == tree_iter.level_stack.items.len - 1) {
                        try stdout_w.interface.print("{s}" ++ hor_pipe ++ hor_pipe ++ "", .{if (l_iter.next() == null) bent_pipe else triple_pipe});

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

                        try cli.termfmt.printDecorated(&stdout_w.interface, decorate, item_text.@"1", "{s}\n", .{item_text.@"0"});
                    } else try stdout_w.interface.print("{s}   ", .{if (l_iter.next() == null) space else vert_pipe});
                }
            }
        },
        .traverse => {
            const DirIter = struct {
                pub const IptCtx = struct {
                    iter: *const IncludeTree,
                    level_stack: *std.ArrayList(bool),
                    decorate: bool,
                    only_include: bool,
                    only_ignore: bool,
                    list_ignore: bool,
                    writer: *std.Io.Writer,
                    allocator: std.mem.Allocator,
                    io: std.Io,
                };

                pub fn iteratePrintDirectory(dir: std.Io.Dir, path: []const u8, level: usize, ipt_ctx: *const IptCtx) !void {
                    var iterator = dir.iterate();
                    const EntryT = struct {
                        kind: std.Io.File.Kind,
                        full_path: []const u8,
                        map_include: ?bool,
                        is_included: bool,

                        pub fn getEntryName(self: @This()) []const u8 {
                            return if (std.mem.lastIndexOfScalar(u8, self.full_path, '/')) |idx| self.full_path[idx + 1 ..] else self.full_path;
                        }
                    };

                    var dir_list: std.ArrayListUnmanaged(EntryT) = .empty;
                    defer dir_list.deinit(ipt_ctx.allocator);

                    while (try iterator.next(ipt_ctx.io)) |entry| {
                        switch (entry.kind) {
                            .directory, .file => |k| {
                                const full_path = try std.mem.join(ipt_ctx.allocator, "/", if (path.len == 0) &.{entry.name} else &.{ path, entry.name });

                                const path_info = ipt_ctx.iter.humanlySortedMapGetPathInfo(full_path, level);
                                const map_include: ?bool = if (path_info.is_map_entry) !path_info.ignore else null;
                                const is_included = if (map_include) |m| m else if (path_info.nested_rules) true else !path_info.ignore;

                                if (!is_included and ipt_ctx.only_include or is_included and ipt_ctx.only_ignore) {
                                    ipt_ctx.allocator.free(full_path);
                                    continue;
                                }

                                try dir_list.append(ipt_ctx.allocator, .{
                                    .kind = k,
                                    .full_path = full_path,
                                    .map_include = map_include,
                                    .is_included = is_included,
                                });
                            },
                            else => continue,
                        }
                    }
                    defer for (dir_list.items) |item| {
                        ipt_ctx.allocator.free(item.full_path);
                    };

                    std.mem.sortUnstable(EntryT, dir_list.items, {}, struct {
                        pub fn lessThan(_: void, lhs: EntryT, rhs: EntryT) bool {
                            return dergdrive.util.sort.humanStringLessThan(lhs.getEntryName(), rhs.getEntryName());
                        }
                    }.lessThan);

                    try ipt_ctx.level_stack.append(ipt_ctx.allocator, true);

                    for (dir_list.items, 0..) |item, i| {
                        if (i == dir_list.items.len - 1)
                            ipt_ctx.level_stack.items[ipt_ctx.level_stack.items.len - 1] = false;

                        for (ipt_ctx.level_stack.items, 0..) |has_next, j| {
                            try ipt_ctx.writer.print("{s} ", .{switch (@as(u2, @intFromBool(j == ipt_ctx.level_stack.items.len - 1)) << 1 | @as(u2, @intFromBool(has_next))) {
                                0b00 => "   ",
                                0b01 => vert_pipe ++ "  ",
                                0b10 => bent_pipe ++ hor_pipe ++ hor_pipe,
                                0b11 => triple_pipe ++ hor_pipe ++ hor_pipe,
                            }});
                        }

                        const item_decor = switch (item.kind) {
                            .directory => &[_]cli.termfmt.Decoration{ .bold, if (item.is_included) .blue else .red },
                            .file => if (item.is_included) &[_]cli.termfmt.Decoration{} else &[_]cli.termfmt.Decoration{.red},
                            else => unreachable,
                        };

                        const entry_name = item.getEntryName();
                        try cli.termfmt.printDecorated(ipt_ctx.writer, ipt_ctx.decorate, item_decor, "{s}\n", .{entry_name});

                        const lvl_empty = if (ipt_ctx.list_ignore or IncludeTree.levelIsIgnore(level)) false else std.sort.binarySearch([]const u8, ipt_ctx.iter.flat_tree.map.keys(), item.full_path, struct {
                            pub fn compareFn(p: []const u8, elem: []const u8) std.math.Order {
                                if (std.mem.startsWith(u8, elem, p))
                                    return .eq;

                                return dergdrive.util.sort.humanStringOrder(p, elem);
                            }
                        }.compareFn) == null;

                        if (item.kind == .directory and !lvl_empty) {
                            var err: ?anyerror = null;
                            if (dir.openDir(ipt_ctx.io, entry_name, .{ .iterate = true })) |d| {
                                if (iteratePrintDirectory(d, item.full_path, if (item.map_include != null) level + 1 else level, ipt_ctx)) |_| {} else |e| err = e;
                            } else |e| err = e;

                            if (err) |e| {
                                for (ipt_ctx.level_stack.items) |has_next| {
                                    try ipt_ctx.writer.print("{s} ", .{if (has_next) vert_pipe ++ "  " else "   "});
                                }

                                try ipt_ctx.writer.writeAll(bent_pipe ++ hor_pipe ++ hor_pipe ++ " ");
                                try cli.termfmt.printDecorated(ipt_ctx.writer, ipt_ctx.decorate, &[_]cli.termfmt.Decoration{.red}, "Couldn't list directory contents due to error: {t}.\n", .{e});
                            }
                        }
                    }

                    _ = ipt_ctx.level_stack.pop();
                }
            };

            const only_include = cli.parser.indexOfOption(args, only_include_opt.long, only_include_opt.short) != null;
            const only_ignore = cli.parser.indexOfOption(args, only_ignore_opt.long, only_ignore_opt.short) != null;

            if (only_include and only_ignore) {
                log.info("Nothing to show.", .{});
                break :sw;
            }

            tree.buildMap() catch |err| {
                log.err("Failed to build include map due to error: {t}.", .{err});
                return error.BuildTreeFailed;
            };

            tree.sortHumanly() catch unreachable;

            var level_stack: std.ArrayList(bool) = .empty;
            defer level_stack.deinit(allocator);

            const ipt_ctx: DirIter.IptCtx = .{
                .iter = &tree,
                .level_stack = &level_stack,
                .decorate = decorate,
                .only_include = only_include,
                .only_ignore = only_ignore,
                .list_ignore = cli.parser.indexOfOption(args, list_ignore_opt.long, list_ignore_opt.short) != null,
                .writer = &stdout_w.interface,
                .allocator = allocator,
                .io = io,
            };

            try DirIter.iteratePrintDirectory(param_vals.root_dir_iterable, "", 1, &ipt_ctx);
        },
    }

    try stdout_w.interface.flush();
}
