const std = @import("std");

const StreamServer = @import("../network/stream_server.zig");
const Connection = @import("../network/connection.zig");
const Stream = @import("stream.zig").Stream;

const Worker = @import("../processing/worker.zig");
const Context = @import("../processing/employer.zig").Context;
const requests = @import("../processing/requests.zig");

const Memory = @import("../storage/memory.zig");

const AccessMiddleware = @import("../middleware/access.zig");

const utils = @import("../utils.zig");
const Logger = @import("../logger.zig");
const consts = @import("consts.zig");

const Listener = @This();

server: *StreamServer,

context: Context,
allocator: std.mem.Allocator,

start: usize = 0,

buffer_size: usize = undefined,

pub fn init(
    allocator: std.mem.Allocator,
    server: *StreamServer,
    context: Context,
    buffer_size: ?usize,
) Listener {
    return .{
        .allocator = allocator,
        .server = server,
        .context = context,
        .buffer_size = buffer_size orelse consts.CLIENT_BUFFER,
    };
}

pub fn listen(self: *Listener, worker: *Worker) void {
    worker.poll_fds[0] = .{
        .revents = 0,
        .fd = self.server.sockfd.?,
        .events = std.posix.POLL.IN,
    };

    while (true) {
        _ = std.posix.poll(worker.poll_fds[self.start..worker.connections], -1) catch |err| {
            self.context.logger.log(
                .Error,
                "# std.os.poll failure: {?}",
                .{err},
            );
            return;
        };

        for (0..worker.connections) |i| {
            const pollfd = worker.poll_fds[i];

            // there is no events for this file descriptor.
            if (pollfd.revents == 0) continue;

            // file descriptor for listening incoming connections
            if (pollfd.fd == self.server.sockfd.?) {
                const handle_result: AcceptResult = self.handle_incoming(worker);
                if (handle_result != .err) continue;

                const err = handle_result.err.etype;
                const connection = handle_result.err.fd;
                if (connection == null) continue;

                switch (err) {
                    // ConnectionAborted aborted is returned when:
                    // - cant set fd to non-block
                    // - cant allocate buffer for incoming connection
                    // - cant set fd to worker states
                    //
                    // NotPermitted is returned when:
                    // - access control fails (that means client is not permitted to connect)
                    error.ConnectionAborted, error.NotPermitted, error.MaxConnections => {
                        // also send message to the client
                        if (connection != null) connection.?.close();
                        continue;
                    },
                    else => continue,
                }
            }

            // file descriptor is ready for reading.
            if (pollfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                const connection = worker.states.getPtr(pollfd.fd) orelse continue;
                self.handle_connection(worker, connection, i);
                continue;
            }

            // treat everything else as error/disconnect
            const connection = worker.states.getPtr(pollfd.fd) orelse continue;
            self.handle_disconnection(worker, connection, i);
        }
    }
}

const AcceptError = struct {
    etype: anyerror,
    fd: ?Stream,
};
const AcceptResult = union(enum) {
    ok: void,
    err: AcceptError,
};
fn handle_incoming(self: *Listener, worker: *Worker) AcceptResult {
    const incoming = self.server.accept() catch |err| {
        const result: AcceptResult = .{
            .err = .{
                .etype = err,
                .fd = null,
            },
        };
        // another thread must have gotten it, no big deal
        if (err == error.WouldBlock) return .{
            .err = .{
                .etype = err,
                .fd = null,
            },
        };

        // this is actuall error.
        self.context.logger.log(
            .Error,
            "# failed to accept new connection: {?}\n",
            .{err},
        );
        return result;
    };

    // stop listening after fds array is full
    if (worker.connections + 1 == worker.poll_fds.len) self.start = 1;
    if (worker.connections + 1 > worker.poll_fds.len) return .{
        .err = .{
            .etype = error.MaxConnections,
            .fd = incoming.stream,
        },
    };

    const access_control = AccessMiddleware.init(self.context.config, self.context.logger);
    access_control.verify(incoming.address) catch return .{
        .err = .{
            .etype = error.NotPermitted,
            .fd = incoming.stream,
        },
    };

    self.context.logger.log(
        .Debug,
        "# new connection from: {any}",
        .{incoming.address},
    );

    worker.poll_fds[worker.connections] = .{
        .revents = 0,
        .fd = incoming.stream.handle,
        .events = std.posix.POLL.IN,
    };

    var connection = Connection.init(
        worker.allocator,
        incoming,
        self.buffer_size,
    ) catch |err| {
        self.context.logger.log(
            .Error,
            "# failed to create client struct: {?}",
            .{err},
        );

        return .{
            .err = .{
                .etype = error.ConnectionAborted,
                .fd = incoming.stream,
            },
        };
    };

    worker.states.put(incoming.stream.handle, connection) catch |err| {
        self.context.logger.log(
            .Error,
            "# failed to put to states: {?}",
            .{err},
        );
        connection.deinit();

        return .{
            .err = .{
                .etype = error.ConnectionAborted,
                .fd = incoming.stream,
            },
        };
    };

    worker.connections += 1;

    return .{ .ok = void{} };
}

fn handle_connection(self: *Listener, worker: *Worker, connection: *Connection, i: usize) void {
    while (true) {
        self.on_receive(worker, connection) catch |err| {
            switch (err) {
                error.WouldBlock => return,
                error.NotOpenForReading => return,
                error.SocketNotConnected => handle_disconnection(
                    self,
                    worker,
                    connection,
                    i,
                ),
                error.ConnectionClosed => return,
                else => connection.close(),
            }
        };
    }
}

fn handle_disconnection(self: *Listener, worker: *Worker, connection: *Connection, i: usize) void {
    self.context.logger.log(
        .Debug,
        "# connection with client closed {any}",
        .{connection.address},
    );

    self.start = 0;

    // remove disconnected by overwiriting it with the last one.
    if (i != worker.connections - 1) {
        worker.poll_fds[i] = worker.poll_fds[worker.connections - 1];
    }

    if (worker.connections > 1) worker.connections -= 1;

    connection.deinit();
    const remove_result = worker.states.remove(connection.fd());
    if (!remove_result) {
        self.context.logger.log(
            .Error,
            "# failed to remove from states",
            .{},
        );
        return;
    }
}

fn on_receive(self: *const Listener, worker: *Worker, connection: *Connection) !void {
    const read_size = try connection.stream.read(connection.buffer[connection.position..]);

    if (read_size == 0) return error.ConnectionClosed;

    const actual_size = connection.position + read_size;
    // resize buffer if actuall is too small.
    if (actual_size == connection.buffer.len) {
        const new_size = actual_size + self.buffer_size;
        connection.resize_buffer(new_size) catch |err| {
            self.context.logger.log(
                .Error,
                "# failed to realloc: {?}",
                .{err},
            );
            return err;
        };
    }

    _ = std.mem.indexOfScalarPos(
        u8,
        connection.buffer[0..actual_size],
        connection.position,
        consts.EXT_CHAR,
    ) orelse {
        // don't have a complete message yet
        connection.position = actual_size;
        return;
    };

    // here we've got the completed message

    connection.position = 0;

    var processor = requests.Processor.init(
        worker.allocator,
        self.context,
    );

    self.context.logger.log_event(.Request, connection.buffer.ptr[0..read_size]);

    // for now only 1 command - 1 response
    processor.process(connection);
}
