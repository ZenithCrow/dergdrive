const std = @import("std");

const dergdrive = @import("dergdrive");
const cli = dergdrive.cli;
const transmit = dergdrive.client.transmit;
const FileReader = transmit.FileReader;
const RequestStorage = transmit.RequestStorage;
const pipe_adapter = transmit.pipe_adapter;
const RequestSender = transmit.RequestSender;
const Cryptor = transmit.Cryptor;

const log = std.log.scoped(.@"cli/commands/test-pipe");

pub const command: cli.Command = .{
    .name = "test-pipe",
    .usage = "test-pipe",
    .desc = "(debug) Test pipe works as expected.",
    .exec_fn = struct {
        pub fn execFn(args: []const []const u8, emap: *std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) cli.Command.ExecError!void {
            return testPipe(args, emap, allocator, io) catch |err| blk: {
                log.err("Command failed due to error: {t}.", .{err});
                break :blk cli.Command.ExecError.ReturnStatusFailure;
            };
        }
    }.execFn,
    .options = &.{},
};

fn testPipe(args: []const []const u8, emap: *const std.process.Environ.Map, allocator: std.mem.Allocator, io: std.Io) !void {
    _ = args;
    _ = emap;

    var req_stor: RequestStorage = .init;
    defer req_stor.deinit(allocator);

    var raw_pa: pipe_adapter.RawFilePipeAdapter = .init;
    var req_pa: pipe_adapter.RequestPipeAdapter = .init;

    var req_sender: RequestSender = try .init(&req_stor, &req_pa, allocator);
    defer req_sender.deinit(allocator);

    var file_reader: FileReader = .{
        .raw_file_adapter = &raw_pa,
        .req_stor = &req_stor,
        .prio_req = &req_sender.prio_request,
    };

    var crypt_cluster: Cryptor.Cluster = .init("klicklicklicklicklicklicklicklic".*, &req_stor, 4);

    try crypt_cluster.initCryptors(allocator);
    defer crypt_cluster.deinitCryptors(allocator);

    crypt_cluster.initializedCryptorsConnectAdapters(&raw_pa, &req_pa);

    try crypt_cluster.runCryptors(.encrypt, io);
    defer crypt_cluster.stopCryptors(io);

    try req_sender.start(io);
    defer req_sender.stop(io);

    const file_path = "/home/vlcaak/wallpapers/autumn-forest-view.png";
    const file = try std.Io.Dir.cwd().openFile(io, file_path, .{});
    defer file.close(io);

    const pipe_info: FileReader.PipeInfo = .{ .path = file_path, .dests = &.{} };
    try file_reader.pipeFile(file, pipe_info, allocator, io);

    try req_stor.reqs_complete_lock.lock(io);
    defer req_stor.reqs_complete_lock.unlock(io);

    log.debug("waiting for pipeline to finish", .{});

    while (req_stor.reqs_piped > req_stor.reqs_complete)
        try req_stor.reqs_complete_cond.wait(io, &req_stor.reqs_complete_lock);

    log.debug("pipeline successfully finished", .{});
}
