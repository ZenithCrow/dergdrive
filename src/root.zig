const std = @import("std");
const builtin = @import("builtin");

pub const client = @import("dergdrive-client");
const fflags = @import("fflags");
pub const is_client = fflags.client_fflag;
pub const is_server = fflags.server_fflag;
pub const server = @import("dergdrive-server");
pub const version = @import("version").v;

pub const crypt = @import("crypt/crypt.zig");

pub const cli = struct {
    pub const commands = struct {
        pub const help = @import("cli/commands/help.zig");
        pub const version = @import("cli/commands/version.zig");
    };
    pub const options = struct {
        pub const help = @import("cli/options/help.zig");
    };
    pub const command_exec = @import("cli/command_exec.zig");
    pub const Command = @import("cli/Command.zig");
    pub const Option = @import("cli/Option.zig");
    pub const parser = @import("cli/parser.zig");
    pub const prompt = @import("cli/prompt.zig");
    pub const termfmt = @import("cli/termfmt.zig");
};

pub const conf = struct {
    pub const Conf = @import("conf/Conf.zig");
    pub const Env = @import("conf/Env.zig");
};

pub const proto = struct {
    pub const sync = struct {
        pub const SyncMessage = @import("proto/sync/SyncMessage.zig");
        pub const RequestChunk = @import("proto/sync/RequestChunk.zig");
        pub const BreakChunk = @import("proto/sync/BreakChunk.zig");
        pub const header = @import("proto/sync/header.zig");
        pub const Chunk = @import("proto/sync/Chunk.zig");
        pub const DestChunk = @import("proto/sync/DestChunk.zig");
        pub const PayloadChunk = @import("proto/sync/PayloadChunk.zig");
        pub const templates = struct {
            pub const UnitAbortMsg = @import("proto/sync/templates/UnitAbortMsg.zig");
            pub const TransmitChunkMsg = @import("proto/sync/templates/TransmitChunkMsg.zig");
            pub const MultipleDestChunksMsg = @import("proto/sync/templates/MultipleDestChunksMsg.zig");
            pub const TransactionAbortMsg = @import("proto/sync/templates/TransactionAbortMsg.zig");
        };
    };
};

pub const util = struct {
    pub const slc = @import("util/slc.zig");
    pub const sort = @import("util/sort.zig");
    pub const shared_slice = @import("util/shared_slice.zig");
};

// pulled from zig 0.15 implementation
pub fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}

test {
    refAllDeclsRecursive(@This());
}
