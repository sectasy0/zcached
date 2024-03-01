const std = @import("std");

const Worker = @import("worker.zig");
const StreamServer = @import("stream_server.zig");
const Connection = @import("connection.zig");
const MemoryStorage = @import("storage.zig");
const Context = @import("employer.zig").Context;

const AccessControl = @import("access_control.zig");
const RequestProcessor = @import("request_processor.zig");

const utils = @import("utils.zig");
const log = @import("logger.zig");

const DEFAULT_CLIENT_BUFFER: usize = 4096;

const Listener = @This();

server: *StreamServer,

context: Context,
allocator: std.mem.Allocator,

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
        .buffer_size = buffer_size orelse DEFAULT_CLIENT_BUFFER,
    };
}

pub fn listen(self: *const Listener, worker: *Worker) void {
    worker.poll_fds[0] = .{
        .revents = 0,
        .fd = self.server.sockfd.?,
        .events = std.os.POLL.IN,
    };

    while (true) {
        _ = std.os.poll(worker.poll_fds[0..worker.connections], -1) catch |err| {
            self.context.logger.log(
                .Error,
                "# std.os.poll failure: {?}\n",
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
                self.handle_incoming(worker) catch |err| {
                    switch (err) {
                        error.MaxConnections => {
                            // should return message to the client
                            self.context.logger.log(
                                .Error,
                                "# failed to connect, max connections reached\n",
                                .{},
                            );

                            std.os.close(pollfd.fd);
                            continue;
                        },
                        // NotPermitted is returned when:
                        // - access control fails (that means client is not permitted to connect)
                        error.NotPermitted => {
                            // also send message to the client
                            std.os.close(pollfd.fd);
                            continue;
                        },
                        // ConnectionAborted aborted is returned when:
                        // - cant set fd to non-block
                        // - cant allocate buffer fo incoming connection
                        // - cant set fd to worker states
                        error.ConnectionAborted => {
                            // also send message to the client
                            std.os.close(pollfd.fd);
                            continue;
                        },
                        else => continue,
                    }
                };
                continue;
            }

            // file descriptor is ready for reading.
            if (pollfd.revents == std.os.POLL.IN) {
                var connection = worker.states.getPtr(pollfd.fd) orelse continue;
                self.handle_connection(connection);
                continue;
            }

            // treat everything else as error/disconnect
            const connection = worker.states.getPtr(pollfd.fd) orelse continue;
            self.handle_disconnection(worker, connection, i);
        }
    }
}

fn handle_incoming(self: *const Listener, worker: *Worker) !void {
    const incoming = self.server.accept() catch |err| {
        // another thread must have gotten it, no big deal
        if (err == error.WouldBlock) return err;

        // this is actuall error.
        self.context.logger.log(
            .Error,
            "# failed to accept new connection: {?}\n",
            .{err},
        );
        return err;
    };

    if (worker.connections == worker.poll_fds.len) return error.MaxConnections;

    const access_control = AccessControl.init(self.context.config, self.context.logger);
    try access_control.verify(incoming.address);

    utils.set_nonblocking(incoming.stream.handle) catch |err| {
        self.context.logger.log(
            .Error,
            "# failed to set client socket to non-blocking: {?}",
            .{err},
        );

        return error.ConnectionAborted;
    };

    self.context.logger.log(
        .Debug,
        "# new connection from: {any}",
        .{incoming.address},
    );

    worker.poll_fds[worker.connections] = .{
        .revents = 0,
        .fd = incoming.stream.handle,
        .events = std.os.POLL.IN,
    };

    var cbuffer = worker.allocator.alloc(u8, self.buffer_size) catch |err| {
        self.context.logger.log(
            .Error,
            "# failed to allocate buffer for client: {?}",
            .{err},
        );

        return error.ConnectionAborted;
    };

    var connection = Connection{
        .buffer = cbuffer,
        .position = 0,
        .stream = incoming.stream,
        .address = incoming.address,
        .allocator = &worker.allocator,
    };

    worker.states.put(incoming.stream.handle, connection) catch |err| {
        self.context.logger.log(
            .Error,
            "# failed to put to states: {?}",
            .{err},
        );
        connection.deinit();

        return error.ConnectionAborted;
    };

    worker.connections += 1;
}

fn handle_connection(self: *const Listener, connection: *Connection) void {
    while (true) {
        self.handle_request(connection) catch |err| {
            switch (err) {
                error.WouldBlock => return,
                error.NotOpenForReading => return,
                else => connection.close(),
            }
        };
    }
}

fn handle_disconnection(self: *const Listener, worker: *Worker, connection: *Connection, i: usize) void {
    connection.deinit();

    self.context.logger.log(
        .Debug,
        "# connection with client closed {any}",
        .{connection.address},
    );

    const remove_result = worker.states.remove(connection.fd());
    if (!remove_result) {
        self.context.logger.log(
            .Error,
            "# failed to remove from states",
            .{},
        );
        return;
    }

    // remove disconnected by overwiriting it with the last one.
    if (i != worker.connections - 1) {
        worker.poll_fds[i] = worker.poll_fds[worker.connections - 1];
    }

    worker.connections -= 1;
}

fn handle_request(self: *const Listener, connection: *Connection) !void {
    const read_size = try connection.stream.read(connection.buffer[connection.position..]);

    if (read_size == 0) return error.ConnectionClosed;

    const actual_size = connection.position + read_size;
    // resize buffer if actuall is too small.
    if (actual_size == connection.buffer.len) {
        const new_size = actual_size + self.buffer_size;
        connection.buffer = connection.allocator.realloc(
            connection.buffer,
            new_size,
        ) catch |err| {
            self.context.logger.log(
                .Error,
                "# failed to realloc: {?}",
                .{err},
            );
            return err;
        };

        connection.buffer = connection.buffer.ptr[0..new_size];
    }

    _ = std.mem.indexOfScalarPos(
        u8,
        connection.buffer[0..actual_size],
        connection.position,
        '\n',
    ) orelse {
        // don't have a complete message yet
        connection.position = actual_size;
        return;
    };

    connection.position = 0;

    var processor = RequestProcessor.init(
        self.allocator,
        self.context,
    );

    // for now only 1 command - 1 response
    processor.process(connection);
}
