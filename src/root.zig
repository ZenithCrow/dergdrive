const std = @import("std");

pub const crypt = @import("crypt/crypt.zig");

pub const cli = struct {
    pub const command_exec = @import("cli/command_exec.zig");
    pub const Command = @import("cli/Command.zig");
    pub const Option = @import("cli/Option.zig");
    pub const parser = @import("cli/parser.zig");
    pub const prompt = @import("cli/prompt.zig");
    pub const termfmt = @import("cli/termfmt.zig");
};

pub const client = struct {
    pub const track = struct {
        pub const IncludeTree = @import("client/track/IncludeTree.zig");
        pub const FileRecordMap = @import("client/track/FileRecordMap.zig");
        pub const Manifest = @import("client/track/Manifest.zig");
        pub const SyncOp = @import("client/track/SyncOp.zig");
    };

    pub const transmit = struct {
        pub const ChunkBuffer = @import("client/transmit/ChunkBuffer.zig");
        pub const Cryptor = @import("client/transmit/Cryptor.zig");
        pub const FileReader = @import("client/transmit/FileReader.zig");
        pub const RawFileChunkBuffer = @import("client/transmit/RawFileChunkBuffer.zig");
        pub const RequestChunkBuffer = @import("client/transmit/RequestChunkBuffer.zig");
        pub const RequestSender = @import("client/transmit/RequestSender.zig");
        pub const RequestStorage = @import("client/transmit/RequestStorage.zig");
        pub const pipe_adapter = @import("client/transmit/pipe_adapter.zig");
    };
};

pub const conf = struct {
    pub const Conf = @import("conf/Conf.zig");
    pub const Env = @import("conf/Env.zig");
};

pub const proto = struct {
    pub const sync = struct {
        pub const SyncMessage = @import("proto/sync/SyncMessage.zig");
        pub const RequestChunk = @import("proto/sync/RequestChunk.zig");
        pub const header = @import("proto/sync/header.zig");
        pub const Chunk = @import("proto/sync/Chunk.zig");
        pub const DestChunk = @import("proto/sync/DestChunk.zig");
        pub const PayloadChunk = @import("proto/sync/PayloadChunk.zig");
        pub const templates = struct {
            pub const TransmitFileMsg = @import("proto/sync/templates/TransmitFileMsg.zig");
        };
    };
};

pub const util = struct {
    pub const sort = @import("util/sort.zig");
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
