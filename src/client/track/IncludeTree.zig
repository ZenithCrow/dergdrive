const std = @import("std");
const expect = std.testing.expect;

const IncludeTree = @This();

pub const IterateDirError = std.fs.Dir.Iterator.Error || std.mem.Allocator.Error || std.fs.Dir.OpenError;

pub const FileNode = []const u8;

pub const DirNode = struct {
    name: []const u8,
    flat_breadth: usize,
};

pub const TreeNode = union(enum) {
    file: FileNode,
    dir: DirNode,

    pub fn path(self: TreeNode) []const u8 {
        return switch (self) {
            .file => |file| file,
            .dir => |dir| dir.name,
        };
    }

    pub fn depth(self: TreeNode) usize {
        return switch (self) {
            .file => 1,
            .dir => |dir| dir.flat_breadth,
        };
    }
};

const log = std.log.scoped(.@"client/track/IncludeTree");

const RuleIterator = struct {
    iterator: std.mem.SplitIterator(u8, .any),

    pub fn init(rule_text: []const u8) RuleIterator {
        return .{ .iterator = std.mem.splitAny(u8, rule_text, "\r\n") };
    }

    pub fn next(self: *RuleIterator) ?[]const u8 {
        return while (self.iterator.next()) |item| {
            const trimmed = std.mem.trim(u8, item, " \t");
            if (trimmed.len == 0 or trimmed[0] == '#')
                continue;

            break trimmed;
        } else null;
    }
};

const MatchIterator = struct {
    path: []const u8,
    is_dir: bool,
    rules: RuleIterator,
    peek_cache: ?[]const u8 = null,
    peek_iter_state: RuleIterator = undefined,

    pub fn init(path: []const u8, is_dir: bool, rules: RuleIterator) MatchIterator {
        return .{ .path = path, .is_dir = is_dir, .rules = rules };
    }

    pub fn next(self: *MatchIterator) ?[]const u8 {
        if (self.peek_cache) |cached| {
            self.peek_cache = null;
            self.rules = self.peek_iter_state;
            return cached;
        }

        return while (self.rules.next()) |r| {
            if (match(self.path, self.is_dir, r))
                break r;
        } else null;
    }

    pub fn peek(self: *MatchIterator) ?[]const u8 {
        var copy = self.*;
        self.peek_cache = copy.next();
        self.peek_iter_state = copy.rules;
        return self.peek_cache;
    }

    /// finds the last matching rule in the iterator without completely consuming it
    pub fn findLastMatch(self: *MatchIterator) ?[]const u8 {
        var last_match: ?[]const u8 = null;
        while (self.peek()) |r| {
            last_match = r;
            _ = self.next();
        }

        return last_match;
    }
};

pub fn swapSlices(comptime T: type, parent: []T, a: []const T, b: []const T) void {
    swapSlicesIdx(T, parent, a.ptr - parent.ptr, a.len, b.ptr - parent.ptr, b.len);
}

pub fn swapSlicesIdx(comptime T: type, arr: []T, a_idx: usize, a_len: usize, b_idx: usize, b_len: usize) void {
    std.debug.assert(a_idx != b_idx);
    std.debug.assert(a_idx + a_len <= b_idx);

    std.mem.reverse(T, arr[a_idx .. a_idx + a_len]);
    std.mem.reverse(T, arr[a_idx + a_len .. b_idx]);
    std.mem.reverse(T, arr[b_idx .. b_idx + b_len]);
    std.mem.reverse(T, arr[a_idx .. b_idx + b_len]);
}

test "swap slices" {
    const allocator = std.testing.allocator;

    const text1 = "hellomom";
    const slc1 = try allocator.dupe(u8, text1);
    defer allocator.free(slc1);

    swapSlicesIdx(u8, slc1, 0, 5, 5, 3);
    try std.testing.expectEqualStrings("momhello", slc1);

    swapSlicesIdx(u8, slc1, 0, 4, 4, 4);
    try std.testing.expectEqualStrings("ellomomh", slc1);

    swapSlicesIdx(u8, slc1, 0, 2, 2, 6);
    try std.testing.expectEqualStrings("lomomhel", slc1);

    const text2 = "moan straight out of hell it's soooooooo gut";
    const slc2 = try allocator.dupe(u8, text2);
    defer allocator.free(slc2);

    swapSlicesIdx(u8, slc2, 6, 8, 32, 9);
    try std.testing.expectEqualStrings("moan soooooooo out of hell it's straight gut", slc2);
}

pub const TreeIterator = struct {
    include_all: bool = false,
    tree: IncludeTree,
    index: usize = 0,
    level_stack: std.ArrayList(LevelledNodesIterator) = .empty,
    excluded_files: std.hash_map.StringHashMapUnmanaged(usize) = .empty,
    level: usize = 1,
    allocator: std.mem.Allocator,

    pub const LevelledNodesIterator = struct {
        flat_tree: []const TreeNode,
        index: usize = 0,
        node_idx: usize = 0,

        pub fn reset(self: *LevelledNodesIterator) void {
            self.index = 0;
            self.node_idx = 0;
        }

        pub fn peek(self: LevelledNodesIterator) ?TreeNode {
            if (self.index >= self.flat_tree.len)
                return null;

            return self.flat_tree[self.index];
        }

        pub fn next(self: *LevelledNodesIterator) ?TreeNode {
            if (self.peek()) |node| {
                self.index += switch (node) {
                    .file => 1,
                    .dir => |dir_node| dir_node.flat_breadth + 1,
                };

                self.node_idx += 1;

                return node;
            } else return null;
        }

        pub fn peekPrev(self: LevelledNodesIterator) ?TreeNode {
            return if (self.node_idx > 0) self.at(self.node_idx - 1) else null;
        }

        pub fn at(self: LevelledNodesIterator, idx: usize) ?TreeNode {
            var iter = self;
            iter.reset();
            var i: usize = 0;
            return while (iter.next()) |n| : (i += 1) {
                if (i == idx)
                    break n;
            } else null;
        }

        pub fn nextBranch(self: *LevelledNodesIterator) ?[]const TreeNode {
            const idx = self.index;
            _ = self.next() orelse return null;
            return self.flat_tree[idx..self.index];
        }

        pub fn branchAt(self: LevelledNodesIterator, idx: usize) ?[]const TreeNode {
            var iter = self;
            iter.reset();
            var i: usize = 0;
            return while (iter.nextBranch()) |b| : (i += 1) {
                if (i == idx)
                    break b;
            } else null;
        }

        pub fn count(self: LevelledNodesIterator) usize {
            var iter = self;
            var c: usize = 0;
            while (iter.next()) |_| : (c += 1) {}
            return c;
        }
    };

    pub fn reset(self: *TreeIterator) void {
        self.index = 0;
        self.level = 1;
        self.level_stack.shrinkRetainingCapacity(0);
    }

    /// To load the excluded path into a map, this function depletes the iterator. Call `reset` to go back to the initial state of the iterator.
    pub fn initExcludes(self: *TreeIterator) std.mem.Allocator.Error!void {
        while (try self.nextNodeLevel()) |res| {
            if (levelIsIgnore(res.level))
                try self.excluded_files.putNoClobber(self.allocator, res.node.path(), self.index - 1);
        }
    }

    pub fn deinit(self: *TreeIterator) void {
        self.level_stack.deinit(self.allocator);
        self.excluded_files.deinit(self.allocator);
    }

    pub fn iterateLevelled(self: TreeIterator, node_idx: usize) ?LevelledNodesIterator {
        return switch (self.tree.flat_tree.items[node_idx]) {
            .file => null,
            .dir => |dir| .{ .flat_tree = self.tree.flat_tree.items[node_idx + 1 .. node_idx + 1 + dir.flat_breadth] },
        };
    }

    pub fn iterateLevelledFromConsumedNode(self: TreeIterator) ?LevelledNodesIterator {
        if (self.index == 0)
            return .{ .flat_tree = self.tree.flat_tree.items };

        return self.iterateLevelled(self.index - 1);
    }

    //  TODO: sort in place instead of this bullshit
    //  NOTE: but I kinda like mess I caused by not wanting to implement my own sort in place :3
    pub fn sortLevelFromConsumedNode(self: TreeIterator) std.mem.Allocator.Error!void {
        var iter = self.iterateLevelledFromConsumedNode() orelse return;
        var hmap: std.StringArrayHashMap(void) = .init(self.allocator);
        defer hmap.deinit();

        const count = iter.count();
        if (count == 0)
            return;

        var iter_cpy = iter;
        try hmap.ensureTotalCapacity(count);
        for (0..count) |_| {
            hmap.putAssumeCapacityNoClobber(iter_cpy.next().?.path(), {});
        }

        hmap.sort(struct {
            self: *@TypeOf(hmap),

            fn @"human -- ehm well derg- naturalCharLessThan"(a: u8, b: u8) std.math.Order {
                const al = std.ascii.toLower(a);
                const bl = std.ascii.toLower(b);
                return if (al != bl) std.math.order(al, bl) else std.math.order(a, b);
            }

            fn humanStringLessThan(lhs_p: []const u8, rhs_p: []const u8) bool {
                const lhs = if (lhs_p.len > 1 and lhs_p[0] == '.') lhs_p[1..] else lhs_p;
                const rhs = if (rhs_p.len > 1 and rhs_p[0] == '.') rhs_p[1..] else rhs_p;

                const n = @min(lhs.len, rhs.len);
                for (lhs[0..n], rhs[0..n]) |lhs_elem, rhs_elem| {
                    switch (@"human -- ehm well derg- naturalCharLessThan"(lhs_elem, rhs_elem)) {
                        .eq => continue,
                        .lt => return true,
                        .gt => return false,
                    }
                }
                return std.math.order(lhs.len, rhs.len) == .lt;
            }

            pub fn lessThan(ctx: @This(), a_i: usize, b_i: usize) bool {
                const keys = ctx.self.keys();
                return humanStringLessThan(keys[a_i], keys[b_i]);
            }
        }{ .self = &hmap });

        const arr: []TreeNode = @constCast(iter.flat_tree);
        for (0..count) |i| {
            var hmap_idx = hmap.getIndex(iter.at(i).?.path()).?;

            while (i != hmap_idx) : ({
                hmap_idx = hmap.getIndex(iter.branchAt(i).?[0].path()).?;
            }) {
                swapSlices(TreeNode, arr, iter.branchAt(i).?, iter.branchAt(hmap_idx).?);
            }
        }
    }

    /// asserts node at index is a dir
    pub fn levelEmpty(self: TreeIterator, node_idx: usize) bool {
        return switch (self.tree.flat_tree.items[node_idx]) {
            .file => unreachable,
            .dir => |dir| dir.flat_breadth == 0,
        };
    }

    pub const NodeLevelResult = struct {
        node: TreeNode,
        level: usize,
    };

    pub fn peekNode(self: TreeIterator) ?TreeNode {
        return if (self.index < self.tree.flat_tree.items.len) self.tree.flat_tree.items[self.index] else null;
    }

    //  TODO: make this same as nextNodeLevel but without advancing the iterator
    /// Don't use this, it doesn't work (at all lol) the same with respect to its relative `nextNodeLevel` function.
    pub fn peekNodeLevel(self: TreeIterator) ?NodeLevelResult {
        if (self.peekNode()) |node| {
            var level = self.level;
            var cur_level_iter = if (level > self.level_stack.items.len) self.iterateLevelledFromConsumedNode().? else self.level_stack.items[level - 1];
            var casc_node = cur_level_iter.next();

            while (casc_node == null and level > 1) {
                level -= 1;
                cur_level_iter = self.level_stack.items[level - 1];
                casc_node = cur_level_iter.next();
            }

            return .{
                .node = node,
                .level = level,
            };
        } else return null;
    }

    pub fn nextNodeLevel(self: *TreeIterator) std.mem.Allocator.Error!?NodeLevelResult {
        if (self.peekNode()) |node| {
            if (self.level > self.level_stack.items.len)
                try self.level_stack.append(self.allocator, self.iterateLevelledFromConsumedNode().?);

            var cur_level_iter: *LevelledNodesIterator = &self.level_stack.items[self.level - 1];
            var casc_node = cur_level_iter.next();

            while (casc_node == null and self.level > 1) {
                _ = self.level_stack.pop();
                self.level -= 1;

                cur_level_iter = &self.level_stack.items[self.level - 1];
                casc_node = cur_level_iter.next();
            }

            const pulled_lvl = self.level;

            if (node == .dir)
                self.level += 1;

            self.index += 1;
            return .{
                .node = node,
                .level = pulled_lvl,
            };
        } else return null;
    }

    pub fn nextNode(self: *TreeIterator) std.mem.Allocator.Error!?TreeNode {
        return if (try self.nextNodeLevel()) |res| res.node else null;
    }
};

const capacity_exp = 16;

flat_tree: std.ArrayList(TreeNode) = .empty,
allocator: std.mem.Allocator,
root_dir: std.fs.Dir,
rules: RuleIterator,

pub fn init(root_dir: std.fs.Dir, rule_text: []const u8, allocator: std.mem.Allocator) IncludeTree {
    return .{ .allocator = allocator, .root_dir = root_dir, .rules = .init(rule_text) };
}

pub fn deinit(self: *IncludeTree) void {
    for (self.flat_tree.items) |item| {
        switch (item) {
            .file => |file_name| self.allocator.free(file_name),
            .dir => |dir| self.allocator.free(dir.name),
        }
    }

    self.flat_tree.deinit(self.allocator);
}

pub fn buildTree(self: *IncludeTree) IterateDirError!void {
    const nodes = try self.iterateDir(self.root_dir, self.rules, 1, "");
    std.debug.assert(nodes == self.flat_tree.items.len);
}

pub fn iterateTree(self: IncludeTree, allocator: std.mem.Allocator) TreeIterator {
    return .{ .tree = self, .allocator = allocator };
}

pub fn sort(self: IncludeTree) std.mem.Allocator.Error!void {
    var tree_iter = self.iterateTree(self.allocator);
    defer tree_iter.deinit();
    try tree_iter.sortLevelFromConsumedNode();

    while (try tree_iter.nextNode()) |_| {
        try tree_iter.sortLevelFromConsumedNode();
    }
}

fn addNode(self: *IncludeTree, node: TreeNode) std.mem.Allocator.Error!usize {
    if (self.flat_tree.items.len == self.flat_tree.capacity)
        try self.flat_tree.ensureTotalCapacity(self.allocator, self.flat_tree.capacity + capacity_exp);

    self.flat_tree.appendAssumeCapacity(node);
    return self.flat_tree.items.len - 1;
}

fn iterateDir(self: *IncludeTree, dir: std.fs.Dir, rule_iter: RuleIterator, level: usize, path: []const u8) IterateDirError!usize {
    var num_nodes_added: usize = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const path_chunks: []const []const u8 = if (path.len == 0) &.{entry.name} else &.{ path, entry.name };

        const FullPath = struct {
            const FullPath = @This();

            path: []const u8,
            allocator: std.mem.Allocator,
            owned: bool = true,

            pub fn deinit(fp: *FullPath) void {
                if (fp.owned)
                    fp.allocator.free(fp.path);
            }

            pub fn transferOwnership(fp: *FullPath) []const u8 {
                fp.owned = false;
                return fp.path;
            }
        };

        var full_path: FullPath = .{ .path = try std.mem.join(self.allocator, "/", path_chunks), .allocator = self.allocator };
        defer full_path.deinit();

        // log.debug("full_path: {s}", .{full_path.path});

        var match_iter: MatchIterator = .init(full_path.path, entry.kind == .directory, rule_iter);
        const prio_rule: ?[]const u8 = match_iter.findLastMatch();

        // if (prio_rule) |rule| log.debug("matched rule: {s}", .{rule});

        var node_index: ?usize = null;
        var node_added = false;
        if (prio_rule) |rule_match| {
            if (ignore(rule_match) == levelIsIgnore(level)) {
                node_added = true;

                switch (entry.kind) {
                    .file => _ = try self.addNode(.{ .file = full_path.transferOwnership() }),
                    .directory => node_index = try self.addNode(.{ .dir = .{ .name = full_path.transferOwnership(), .flat_breadth = 0 } }),
                    else => {
                        //  TODO: handle symlinks
                        node_added = false;
                    },
                }

                if (node_added)
                    num_nodes_added += 1;
            }
        }

        if (entry.kind == .directory) {
            const level_inc: usize = if (node_added) 1 else 0;
            if (searchForChildRules(full_path.path, match_iter.rules, level + level_inc)) {
                var child_dir = try dir.openDir(entry.name, .{ .iterate = true });
                defer child_dir.close();

                const child_iter = if (node_added) match_iter.rules else rule_iter;
                const child_dir_nodes = try self.iterateDir(child_dir, child_iter, level + level_inc, full_path.path);

                if (node_index) |index| {
                    switch (self.flat_tree.items[index]) {
                        .dir => |*dir_node| dir_node.flat_breadth += child_dir_nodes,
                        else => unreachable,
                    }
                }

                num_nodes_added += child_dir_nodes;
            }
        }
    }

    return num_nodes_added;
}

pub inline fn ignore(rule: []const u8) bool {
    return rule.len > 0 and rule[0] == '!';
}

pub inline fn levelIsIgnore(level: usize) bool {
    return level % 2 == 0;
}

fn searchForChildRules(parent_path: []const u8, rule_iter: RuleIterator, level: usize) bool {
    var iter = rule_iter;
    return while (iter.next()) |rule| {
        if (canHaveChild(parent_path, rule, level)) {
            // log.debug("found child rule: {s}", .{rule});
            break true;
        }
    } else false;
}

fn canHaveChild(parent_path: []const u8, rule: []const u8, level: usize) bool {
    if (levelIsIgnore(level) != ignore(rule))
        return false;

    if (canMatchAnywhere(rule))
        return true;

    var rule_mut = rule;
    var rule_slashes = std.mem.count(u8, rule_mut, "/");
    const parent_slashes = std.mem.count(u8, parent_path, "/");
    const double_ast = std.mem.indexOf(u8, rule_mut, "**") != null;

    return while (rule_mut.len > 0 and (rule_slashes >= parent_slashes or double_ast)) : ({
        const slash_end = std.mem.lastIndexOfScalar(u8, rule_mut, '/') orelse 0;
        rule_mut = rule_mut[0..slash_end];
        rule_slashes -|= 1;
    }) {
        if (match(parent_path, true, rule_mut))
            break true;
    } else false;
}

fn match(path: []const u8, is_dir: bool, rule: []const u8) bool {
    if (rule.len < 1)
        return false;

    var rule_mut = std.mem.trimStart(u8, rule, "!");
    if (rule_mut.len < 1)
        return false;

    if (rule_mut[rule_mut.len - 1] == '/' and !is_dir)
        return false;

    const match_end = canMatchAnywhere(rule_mut);

    rule_mut = std.mem.trim(u8, rule_mut, "/");
    if (rule_mut.len < 1)
        return false;

    var rule_iter = std.mem.splitScalar(u8, rule_mut, '*');
    var path_pos: usize = if (match_end) blk: {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |pos| break :blk pos + 1 else break :blk 0;
    } else 0;

    var rule_chunk_matched = false;
    return while (rule_iter.next()) |rule_chunk| {
        var rule_chunk_mut = rule_chunk;
        const peek_rule = rule_iter.peek();

        if (rule_chunk_mut.len == 0) {
            if (rule_iter.index != 1 and peek_rule != null) {
                var next_rule = peek_rule orelse unreachable;
                if (next_rule.len == 0) {
                    if (path_pos == 0)
                        break true;

                    break path[path_pos - 1] == '/';
                }

                if (!matchRuleChunk(path, &path_pos, &next_rule, false))
                    break false;

                rule_chunk_matched = true;
                continue;
            }
        } else if (!rule_chunk_matched) {
            if (!matchRuleChunk(path, &path_pos, &rule_chunk_mut, true))
                break false;
        }

        rule_chunk_matched = false;

        if (peek_rule) |peek| {
            const next_slash = std.mem.indexOfPos(u8, path, path_pos, "/");

            if (peek.len > 0) {
                if (peek[0] == '/') {
                    if (next_slash) |pos| {
                        path_pos = pos + 1;
                    } else break false;
                } else {
                    var next_rule = peek;
                    const max_pos = next_slash orelse path.len;

                    if (!matchRuleChunk(path, &path_pos, &next_rule, false) or path_pos - next_rule.len >= max_pos)
                        break false;

                    rule_chunk_matched = true;
                }
            } else if (rule_iter.index == rule_mut.len) {
                if (rule_chunk.len > 0 and rule_chunk[rule_chunk.len - 1] == '/' and path[path_pos - 1] != '/')
                    break false;

                path_pos = next_slash orelse path.len;
            }
        }
    } else path_pos == path.len;
}

fn canMatchAnywhere(rule: []const u8) bool {
    const slash_pos = std.mem.indexOfScalar(u8, rule, '/');
    return slash_pos == null or slash_pos == rule.len - 1;
}

fn matchRuleChunk(path: []const u8, path_pos: *usize, rule_chunk: *[]const u8, strict: bool) bool {
    rule_chunk.* = std.mem.trim(u8, rule_chunk.*, "/");
    path_pos.* = if (std.mem.indexOfPos(u8, path, path_pos.*, rule_chunk.*)) |pos| blk: {
        if (strict and pos != path_pos.*)
            return false;

        break :blk pos + rule_chunk.len;
    } else return false;

    if (path_pos.* + 1 < path.len and path[path_pos.*] == '/')
        path_pos.* += 1;

    return true;
}

test "match path chunk" {
    const path = "foo/owo/bar";
    var path_pos: usize = 0;
    var rule: []const u8 = "foo/";
    try expect(IncludeTree.matchRuleChunk(path, &path_pos, &rule, false));
    rule = "/bar";
    try expect(IncludeTree.matchRuleChunk(path, &path_pos, &rule, false));
    try expect(path_pos == path.len);
}

test "match path anywhere" {
    try expect(IncludeTree.match("foo", false, "foo"));
    try expect(IncludeTree.match("foo", false, "/foo"));
    try expect(!IncludeTree.match("foo", false, "/foo/"));
    try expect(IncludeTree.match("foo", true, "/foo/"));

    try expect(IncludeTree.match("foo/bar", false, "bar"));
    try expect(IncludeTree.match("foo/owo/bar", false, "bar"));
    try expect(!IncludeTree.match("foo/owo/bar", false, "owo"));
    try expect(!IncludeTree.match("foo/owo/bar", false, "foo"));
    try expect(!IncludeTree.match("foo/bar", false, "bar/"));
    try expect(IncludeTree.match("foo/owo/bar", true, "bar/"));
    try expect(!IncludeTree.match("foo/owo/bar", false, "owo/bar"));
}

test "match single ast wildcard" {
    try expect(IncludeTree.match("owo", false, "*"));
    try expect(!IncludeTree.match("owo", false, "*/"));
    try expect(IncludeTree.match("owo", true, "*/"));
    try expect(IncludeTree.match("foo.txt", false, "foo.*"));
    try expect(IncludeTree.match("foo.exe", false, "foo.*"));
    try expect(IncludeTree.match("foo.txt", false, "*.txt"));
    try expect(IncludeTree.match("bar.txt", false, "*.txt"));
    try expect(IncludeTree.match("foo/owo/bar", false, "foo/*/bar"));
    try expect(IncludeTree.match("foo/owo/bar", false, "foo/*wo/bar"));
    try expect(IncludeTree.match("foo/owo/bar", false, "foo/o*/bar"));
    try expect(!IncludeTree.match("foo/owo/bar", false, "foo/*ar"));
    try expect(!IncludeTree.match("foo", false, "foo/*"));
    try expect(IncludeTree.match("foo/bar", false, "foo/*"));
    try expect(!IncludeTree.match("foo/bar/owo", false, "foo/*"));

    // matches the first occurence of the rule chunk after wildcard
    try expect(!IncludeTree.match("foo", false, "f*o"));
    try expect(IncludeTree.match("foo/owo/bar", false, "f*o/ow*/bar"));
    try expect(IncludeTree.match("foo/owo/bar", false, "foo/*w*/bar"));
    try expect(!IncludeTree.match("foo", false, "foo/**"));
}

test "match double ast wildcard" {
    try expect(IncludeTree.match("foo/owo/bar", true, "foo/owo/**/"));
    try expect(IncludeTree.match("foo/owo/bar", true, "foo/**/bar/"));
    try expect(IncludeTree.match("foo/owo/bar", true, "**/owo/bar/"));
}

test "can have child" {
    try expect(IncludeTree.canHaveChild("foo", "bar", 1));
    try expect(!IncludeTree.canHaveChild("foo", "bar", 2));
    try expect(IncludeTree.canHaveChild("foo", "foo/bar/", 1));
    try expect(IncludeTree.canHaveChild("foo", "**/", 1));
    try expect(IncludeTree.canHaveChild("foo", "**/owo", 1));
    try expect(!IncludeTree.canHaveChild("foo", "bar/**/owo", 1));
    try expect(IncludeTree.canHaveChild("foo", "foo/**/owo", 1));
    try expect(IncludeTree.canHaveChild("foo", "*/owo", 1));
    try expect(!IncludeTree.canHaveChild("foo/bar/baz", "*/owo", 1));
}
