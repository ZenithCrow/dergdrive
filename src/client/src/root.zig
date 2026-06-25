const dergdrive = @import("dergdrive");

pub const Conf = @import("Conf.zig");
pub const SecAuth = @import("SecAuth.zig");

pub const cli = struct {
    pub const command_exec = @import("cli/command_exec.zig");
    pub const service = @import("cli/service.zig");

    pub const commands = struct {
        pub const @"ls-include" = @import("cli/commands/ls-include.zig");
        pub const @"test-pipe" = @import("cli/commands/test-pipe.zig");
        pub const @"test-sync" = @import("cli/commands/test-sync.zig");
        pub const @"probe-server" = @import("cli/commands/probe-server.zig");
    };

    pub const options = struct {
        pub const @"include-rules" = @import("cli/options/include-rules.zig");
        pub const vol = @import("cli/options/vol.zig");
        pub const server = @import("cli/options/server.zig");
    };
};

pub const track = struct {
    pub const IncludeTree = @import("track/IncludeTree.zig");
    pub const FileRecordMap = @import("track/FileRecordMap.zig");
    pub const Manifest = @import("track/Manifest.zig");
    pub const SyncOp = @import("track/SyncOp.zig");
    pub const unit_sync = @import("track/unit_sync.zig");
};

pub const rxtx = struct {
    pub const ChunkBuffer = @import("rxtx/ChunkBuffer.zig");
    pub const Cryptor = @import("rxtx/Cryptor.zig");
    pub const FileReader = @import("rxtx/FileReader.zig");
    pub const RawFileChunkBuffer = @import("rxtx/RawFileChunkBuffer.zig");
    pub const RequestChunkBuffer = @import("rxtx/RequestChunkBuffer.zig");
    pub const RequestReceiver = @import("rxtx/RequestReceiver.zig");
    pub const RequestSender = @import("rxtx/RequestSender.zig");
    pub const RequestStorage = @import("rxtx/RequestStorage.zig");
    pub const pipe_adapter = @import("rxtx/pipe_adapter.zig");
    pub const PrioRequest = @import("rxtx/PrioRequest.zig");
};

test {
    dergdrive.refAllDeclsRecursive(@This());
}
