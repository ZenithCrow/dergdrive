pub const cli = struct {
    pub const commands = struct {
        pub const server = @import("cli/commands/server.zig");
        pub const @"run-pings" = @import("cli/commands/run-pings.zig");
    };
    pub const command_exec = @import("cli/command_exec.zig");
};

pub const rxtx = struct {
    pub const ConnectionWorker = @import("rxtx/ConnectionWorker.zig");
    pub const NetAcceptor = @import("rxtx/NetAcceptor.zig");
};
