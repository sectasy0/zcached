const std = @import("std");

// Middleware
const AccessMiddleware = @import("../middleware/access.zig");

// Networking
const Connection = @import("../network/connection.zig");
const StreamServer = @import("../network/stream_server.zig");
const Stream = @import("stream.zig").Stream;

// Processing / application logic
const Context = @import("../processing/employer.zig").Context;
const requests = @import("../processing/requests.zig");
const Worker = @import("../processing/worker.zig");

const Warden = @This();

start: usize = 0,

allocator: std.mem.Allocator,
context: Context,

access_control: AccessMiddleware,

const AcceptError = struct {
    etype: anyerror,
    fd: ?Stream,
};

const AcceptResult = union(enum) {
    ok: void,
    err: AcceptError,
};

pub fn init(allocator: std.mem.Allocator, context: Context) Warden {
    return .{
        .allocator = allocator,
        .context = context,
        .access_control = AccessMiddleware.init(context.config, context.logger),
    };
}

pub fn setupConnection(self: *Warden, worker: *Worker, incoming: StreamServer.Connection) AcceptResult {
    // stop listening after fds array is full
    if (worker.connections + 1 == worker.poll_fds.len) self.start = 1;
    if (worker.connections + 1 > worker.poll_fds.len) return .{
        .err = .{
            .etype = error.MaxConnections,
            .fd = incoming.stream,
        },
    };

    self.access_control.verify(incoming.address) catch return .{
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
        &worker.poll_fds[worker.connections],
        worker.connections,
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

pub fn dispatch(self: *Warden, worker: *Worker, connection: *Connection) void {
    while (true) {
        self._processIncoming(worker, connection) catch |err| {
            switch (err) {
                error.WouldBlock, error.NotOpenForReading => return,
                error.SocketNotConnected,
                error.ConnectionResetByPeer,
                error.BrokenPipe,
                error.OperationAborted,
                error.SSLProtocolError,
                error.ConnectionClosed,
                => self.teardownConnection(worker, connection),
                else => {
                    self.context.logger.log(
                        .Error,
                        "Unexpected read error: {?}, disconnecting.",
                        .{err},
                    );

                    connection.close();
                },
            }
        };
    }
}

pub fn handleOutgoing(self: *Warden, worker: *Worker, connection: *Connection) void {
    const write_size = connection.tx_accumulator.items.len;

    if (write_size == 0) {
        // no data to write, remove the OUT event
        connection.clearWritable();
        return;
    }

    connection.writePending() catch |err| {
        switch (err) {
            error.WouldBlock => {
                // cant write right now, but we will try again later
                connection.signalWritable();
                return;
            },
            // these errors mean that we can't write to the stream, do nothin
            error.NotOpenForWriting => self.teardownConnection(worker, connection),
            error.ConnectionResetByPeer,
            error.BrokenPipe,
            error.OperationAborted,
            error.SSLProtocolError,
            => self.teardownConnection(worker, connection),
            else => {
                self.context.logger.log(
                    .Error,
                    "# failed to write to stream: {?}",
                    .{err},
                );
                // if we can't write, close the connection
                self.teardownConnection(worker, connection);
                return;
            },
        }
    };

    // remove written data from the tx_accumulator
    connection.tx_accumulator.clearRetainingCapacity();
}

pub fn teardownConnection(
    self: *Warden,
    worker: *Worker,
    connection: *Connection,
) void {
    self.context.logger.log(
        .Debug,
        "# connection with client closed {any}",
        .{connection.address},
    );

    self.start = 0;

    // remove disconnected by overwiriting it with the last one.
    if (connection.id != worker.connections - 1) {
        const last_fd = worker.poll_fds[worker.connections - 1];
        // need to get the last connection from the states and change its id
        var last_connection = worker.states.get(last_fd.fd) orelse {
            self.context.logger.log(
                .Error,
                "# failed to get last connection from states: {any}",
                .{last_fd.fd},
            );
            return;
        };

        last_connection.id = connection.id;
        worker.poll_fds[connection.id] = last_fd;
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

fn _processIncoming(self: *const Warden, worker: *Worker, connection: *Connection) !void {
    const max_size = self.context.config.max_request_size;
    connection.readPending(max_size) catch |err| {
        switch (err) {
            error.IncompleteMessage => return,
            error.MessageTooLarge => {
                self.context.logger.log(
                    .Error,
                    "# message too large, max size is {d} bytes",
                    .{max_size},
                );
                return error.RequestTooLarge;
            },
            else => return err,
        }
    };

    // here we've got the completed message, let's process it

    var processor = requests.Processor.init(
        worker.allocator,
        self.context,
    );

    self.context.logger.log_event(.Request, connection.accumulator.items);

    // for now only 1 command - 1 response
    processor.process(connection);

    connection.accumulator.clearRetainingCapacity();
}
