const dergdrive = @import("dergdrive");

pub const cli = struct {
    pub const command_exec = @import("cli/command_exec.zig");

    pub const commands = struct {
        pub const @"ls-include" = @import("cli/commands/ls-include.zig");
        pub const @"test-pipe" = @import("cli/commands/test-pipe.zig");
        pub const @"test-sync" = @import("cli/commands/test-sync.zig");
    };

    pub const options = struct {
        pub const @"include-rules" = @import("cli/options/include-rules.zig");
        pub const vol = @import("cli/options/vol.zig");
    };
};

pub const conf = struct {
    pub const Conf = @import("conf/Conf.zig");
};

pub const track = struct {
    pub const IncludeTree = @import("track/IncludeTree.zig");
    pub const FileRecordMap = @import("track/FileRecordMap.zig");
    pub const Manifest = @import("track/Manifest.zig");
    pub const SyncOp = @import("track/SyncOp.zig");
    pub const unit_sync = @import("track/unit_sync.zig");
};

pub const transmit = struct {
    pub const ChunkBuffer = @import("transmit/ChunkBuffer.zig");
    pub const Cryptor = @import("transmit/Cryptor.zig");
    pub const FileReader = @import("transmit/FileReader.zig");
    pub const RawFileChunkBuffer = @import("transmit/RawFileChunkBuffer.zig");
    pub const RequestChunkBuffer = @import("transmit/RequestChunkBuffer.zig");
    pub const RequestSender = @import("transmit/RequestSender.zig");
    pub const RequestStorage = @import("transmit/RequestStorage.zig");
    pub const pipe_adapter = @import("transmit/pipe_adapter.zig");
    pub const PrioRequest = @import("transmit/PrioRequest.zig");
};

test {
    dergdrive.refAllDeclsRecursive(@This());
}
