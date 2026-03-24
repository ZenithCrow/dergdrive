const std = @import("std");

pub const crypt = @import("crypt/crypt.zig");

pub const cli = struct {
    pub const prompt = @import("cli/prompt.zig");
};

pub const client = struct {
    pub const track = struct {
        pub const IncludeTree = @import("client/track/IncludeTree.zig");
        pub const Manifest = @import("client/track/Manifest.zig");
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

test {
    std.testing.refAllDeclsRecursive(@This());
}
