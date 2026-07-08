const std = @import("std");
const net = std.Io.net;

const server = @import("server");
const GlobCtx = server.GlobCtx;

const Connection = @import("Connection.zig");
const ConnectionWorker = @import("ConnectionWorker.zig");
const QuickRespService = @import("QuickRespService.zig");

const NetAcceptor = @This();

pub const AcceptLoopError = net.IpAddress.ListenError || net.Server.AcceptError || std.mem.Allocator.Error || std.Io.ConcurrentError;

const log = std.log.scoped(.@"server/rxtx/NetAcceptor");

pub const ConnectionTask = struct {
    node: std.DoublyLinkedList.Node,
    conn: Connection,
};

port: u16,
glob_ctx: *const GlobCtx,
connections: std.DoublyLinkedList,
conn_lock: std.Io.Mutex = .init,
accept_task: ?std.Io.Future(AcceptLoopError!void) = null,

pub fn init(port: u16, glob_ctx: *const GlobCtx) NetAcceptor {
    return .{
        .port = port,
        .glob_ctx = glob_ctx,
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

    log.debug("Cleaned up connection from {f}.", .{task.conn.worker.stream.socket.address});

    task.conn.worker.stop(io);
    task.conn.worker.stream.close(io);
    task.conn.worker.deinit(gpa, io);

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

fn cleanUpInactiveConnections(self: *NetAcceptor, gpa: std.mem.Allocator, io: std.Io) void {
    self.conn_lock.lockUncancelable(io);
    defer self.conn_lock.unlock(io);

    var prev_node: ?*std.DoublyLinkedList.Node = null;
    while (self.connections.last != prev_node) {
        const cur_node = if (prev_node) |pn| pn.next.? else self.connections.first.?;
        const task: *ConnectionTask = @fieldParentPtr("node", cur_node);

        const clean_up = blk: {
            task.conn.worker.active_lock.lockUncancelable(io);
            defer task.conn.worker.active_lock.unlock(io);

            break :blk !task.conn.worker.active;
        };

        if (clean_up) {
            self.conn_lock.unlock(io);
            defer self.conn_lock.lockUncancelable(io);

            self.deinitTask(task, gpa, io);
        } else prev_node = cur_node;
    }
}

fn acceptLoop(self: *NetAcceptor, gpa: std.mem.Allocator, io: std.Io) AcceptLoopError!void {
    const ip4: net.Ip4Address = .unspecified(self.port);
    const addr: net.IpAddress = .{ .ip4 = ip4 };
    var tcp_server = try addr.listen(io, .{});
    defer tcp_server.deinit(io);

    while (true) {
        // clean up connections after successful or timed out accept
        self.cleanUpInactiveConnections(gpa, io);

        const stream = blk: {
            var l: std.Io.Mutex = .init;
            var c: std.Io.Condition = .init;
            var event: bool = false;
            var possible_stream: error{Timeout}!net.Stream = undefined;

            var acc_future = try io.concurrent(struct {
                pub fn acceptFn(s: *net.Server, lock: *std.Io.Mutex, cond: *std.Io.Condition, io_a: std.Io, out_event: *bool, out_stream: *(error{Timeout}!net.Stream)) net.Server.AcceptError!void {
                    const stream = try s.accept(io_a);
                    errdefer stream.close(io_a);

                    {
                        try lock.lock(io_a);
                        defer lock.unlock(io_a);

                        out_stream.* = stream;
                        out_event.* = true;
                    }

                    cond.signal(io_a);
                }
            }.acceptFn, .{ &tcp_server, &l, &c, io, &event, &possible_stream });
            defer acc_future.cancel(io) catch {};

            var tout_future = try io.concurrent(struct {
                pub fn timeoutFn(lock: *std.Io.Mutex, cond: *std.Io.Condition, io_t: std.Io, out_event: *bool, out_stream: *error{Timeout}!net.Stream) std.Io.Cancelable!void {
                    try io_t.sleep(.fromSeconds(5), .awake);

                    {
                        try lock.lock(io_t);
                        defer lock.unlock(io_t);

                        if (!out_event.*) {
                            out_stream.* = error.Timeout;
                            out_event.* = true;
                        }
                    }

                    cond.signal(io_t);
                }
            }.timeoutFn, .{ &l, &c, io, &event, &possible_stream });
            defer tout_future.cancel(io) catch {};

            try l.lock(io);
            defer l.unlock(io);

            while (!event)
                try c.wait(io, &l);

            if (possible_stream != error.Timeout)
                break :blk possible_stream catch unreachable;

            continue;
        };
        errdefer stream.close(io);
        log.info("Accepted connection from {f}.", .{stream.socket.address});

        var cw: ConnectionWorker = try .init(stream, gpa);
        errdefer cw.deinit(gpa, io);

        const conn_task = try gpa.create(ConnectionTask);
        errdefer gpa.destroy(conn_task);

        conn_task.* = .{
            .node = .{},
            .conn = .{
                .worker = cw,
                .sec_auth = .init(null, io),
            },
        };
        conn_task.conn.sec_auth.sign_key_pair = self.glob_ctx.sign_key_pair;

        QuickRespService.fillHandshake(conn_task.conn.sec_auth, conn_task.conn.worker.write_buf[0..QuickRespService.handshake_len], io) catch |err| {
            log.err("Failed to fill handshake with {f} due to error: {t}. Refusing connection.", .{ stream.socket.address, err });
            continue;
        };
        conn_task.conn.worker.write_data_len = QuickRespService.handshake_len;

        try conn_task.conn.worker.start(io);
        errdefer conn_task.conn.worker.stop(io);

        {
            try self.conn_lock.lock(io);
            defer self.conn_lock.unlock(io);

            self.connections.append(&conn_task.node);
        }
    }
}
