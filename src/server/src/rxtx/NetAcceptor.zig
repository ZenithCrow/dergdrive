const std = @import("std");
const net = std.Io.net;

const ConnectionWorker = @import("ConnectionWorker.zig");

const NetAcceptor = @This();

pub const AcceptLoopError = net.IpAddress.ListenError || net.Server.AcceptError || std.mem.Allocator.Error || std.Io.ConcurrentError;

const log = std.log.scoped(.@"server/rxtx/NetAcceptor");

pub const ConnectionTask = struct {
    node: std.DoublyLinkedList.Node,
    conn_worker: ConnectionWorker,
};

port: u16,
connections: std.DoublyLinkedList,
conn_lock: std.Io.Mutex = .init,
accept_task: ?std.Io.Future(AcceptLoopError!void) = null,

pub fn init(port: u16) NetAcceptor {
    return .{
        .port = port,
        .connections = .{},
    };
}

pub fn deinit(self: *NetAcceptor, gpa: std.mem.Allocator, io: std.Io) void {
    self.stop(io);

    self.conn_lock.lockUncancelable(io);
    defer self.conn_lock.unlock(io);

    while (self.connections.first != null) {
        const node = self.connections.pop() orelse unreachable;
        const task: *ConnectionTask = @fieldParentPtr("node", node);

        {
            self.conn_lock.unlock(io);
            defer self.conn_lock.lockUncancelable(io);

            self.deinitTask(task, gpa, io);
        }
    }
}

pub fn deinitTask(self: *NetAcceptor, task: *ConnectionTask, gpa: std.mem.Allocator, io: std.Io) void {
    {
        self.conn_lock.lockUncancelable(io);
        defer self.conn_lock.unlock(io);

        self.connections.remove(&task.node);
    }

    log.debug("Cleaned up connection from {f}.", .{task.conn_worker.stream.socket.address});

    task.conn_worker.stop(io);
    task.conn_worker.stream.close(io);
    task.conn_worker.deinit(gpa, io);

    gpa.destroy(task);
}

pub fn start(self: *NetAcceptor, gpa: std.mem.Allocator, io: std.Io) std.Io.ConcurrentError!void {
    std.debug.assert(self.accept_task == null);

    self.accept_task = try io.concurrent(acceptLoop, .{ self, gpa, io });
}

/// idempotent
pub fn stop(self: *NetAcceptor, io: std.Io) void {
    if (self.accept_task) |*t| {
        t.cancel(io) catch |err| switch (err) {
            AcceptLoopError.Canceled => {},
            else => log.warn("Collecting net accept task with error: {t}.", .{err}),
        };
        self.accept_task = null;
    }
}

fn acceptLoop(self: *NetAcceptor, gpa: std.mem.Allocator, io: std.Io) AcceptLoopError!void {
    const ip4: net.Ip4Address = .unspecified(self.port);
    const addr: net.IpAddress = .{ .ip4 = ip4 };
    var tcp_server = try addr.listen(io, .{});
    defer tcp_server.deinit(io);

    while (true) {
        const stream = try tcp_server.accept(io);
        errdefer stream.close(io);
        log.debug("Accepted connection from {f}.", .{stream.socket.address});

        var cw: ConnectionWorker = try .init(stream, gpa);
        errdefer cw.deinit(gpa, io);

        const conn_task = try gpa.create(ConnectionTask);
        errdefer gpa.destroy(conn_task);

        conn_task.* = .{
            .node = .{},
            .conn_worker = cw,
        };

        try conn_task.conn_worker.start(io);
        errdefer conn_task.conn_worker.stop(io);

        {
            try self.conn_lock.lock(io);
            defer self.conn_lock.unlock(io);

            self.connections.append(&conn_task.node);
        }
    }
}
