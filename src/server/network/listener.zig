const std = @import("std");
const runtime_io = @import("runtime_io");
const AccessMiddleware = @import("../middleware/access.zig");
const Connection = @import("connection.zig");
const StreamServer = @import("stream_server.zig");
const Context = @import("../context.zig");
const Processor = @import("../processing/requests.zig").Processor;

const Listener = @This();

server: *StreamServer,
context: Context,
allocator: std.mem.Allocator,
slots: std.Io.Semaphore,

pub fn init(allocator: std.mem.Allocator, server: *StreamServer, context: Context) Listener {
    return .{
        .allocator = allocator,
        .server = server,
        .context = context,
        .slots = .{ .permits = context.config.max_clients },
    };
}

pub fn listen(self: *Listener) std.Io.Cancelable!void {
    const io = runtime_io.get();
    var connections: std.Io.Group = .init;
    defer connections.cancel(io);

    while (self.context.running.load(.seq_cst)) {
        try self.slots.wait(io);
        const incoming = self.server.accept() catch |err| {
            self.slots.post(io);
            if (err == error.Canceled) return error.Canceled;
            if (err == error.ConnectionAborted) continue;
            self.context.resources.logger.err("# accept failed: {any}", .{err});
            self.context.running.store(false, .seq_cst);
            return;
        };

        connections.concurrent(io, serve, .{ self, incoming }) catch |err| {
            var stream = incoming.stream;
            stream.close();
            self.slots.post(io);
            if (err == error.Canceled) return error.Canceled;
            self.context.resources.logger.err("# failed to start connection task: {any}", .{err});
        };
    }
}

fn serve(self: *Listener, incoming: StreamServer.Connection) std.Io.Cancelable!void {
    const io = runtime_io.get();
    defer self.slots.post(io);
    var accepted = incoming;
    defer accepted.stream.close();

    var access = AccessMiddleware.init(self.context.config, self.context.resources.logger);
    access.verify(accepted.address) catch return;

    self.server.upgrade(&accepted.stream) catch |err| {
        if (err == error.Canceled) return error.Canceled;
        self.context.resources.logger.err("# TLS handshake failed: {any}", .{err});
        return;
    };

    var connection = Connection.init(self.allocator, accepted) catch |err| {
        self.context.resources.logger.err("# failed to initialize connection: {any}", .{err});
        return;
    };
    defer connection.deinit();
    var processor = Processor.init(self.allocator, self.context) catch |err| {
        self.context.resources.logger.err("# failed to initialize request processor: {any}", .{err});
        return;
    };
    defer processor.deinit();

    self.context.resources.logger.info("# new connection from: {any}", .{accepted.address});
    defer self.context.resources.logger.info("# connection with client closed: {any}", .{accepted.address});

    while (self.context.running.load(.seq_cst)) {
        connection.readPending(self.context.config.max_request_size) catch |err| {
            switch (err) {
                error.IncompleteMessage => continue,
                error.Canceled => return error.Canceled,
                error.ConnectionClosed, error.ConnectionResetByPeer, error.SocketUnconnected => return,
                else => {
                    self.context.resources.logger.err("# failed to read request: {any}", .{err});
                    return;
                },
            }
        };
        processor.deframe(&connection);
        connection.writePending() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.context.resources.logger.err("# failed to write response: {any}", .{err});
            return;
        };
    }
}
