const std = @import("std");
const runtime_io = @import("runtime_io");
const build_options = @import("build_options");
const access = @import("../middleware/access.zig");
const Connection = @import("connection.zig");
const StreamServer = @import("stream_server.zig");
const Context = @import("../context.zig");
const Processor = @import("../processing/requests.zig").Processor;

const Server = @This();

transport: StreamServer,
context: Context,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, context: Context) !Server {
    if (context.config.workers == 0 or context.config.max_clients == 0) return error.InvalidWorkerConfig;

    if (context.config.tls.enabled and build_options.tls_enabled) {
        context.resources.logger.info("# zcached is running with TLS enabled", .{});
    }

    return .{
        .transport = try StreamServer.init(.{
            .reuse_address = true,
            .tls = context.config.tls,
        }),
        .context = context,
        .allocator = allocator,
    };
}

pub fn run(self: *Server) void {
    self.context.resources.logger.info("# starting zcached server on tcp://{any} | Workers {}", .{
        self.context.config.address,
        self.context.config.workers,
    });
    self.transport.listen(self.context.config.getAddress()) catch |err| {
        self.context.resources.logger.err(
            "# failed to run server listener: {any}",
            .{err},
        );
        return;
    };

    const io = runtime_io.get();
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);

    for (0..self.context.config.workers) |_| {
        workers.concurrent(io, acceptConnections, .{self}) catch |err| {
            self.context.resources.logger.err(
                "# failed to start listener task: {any}",
                .{err},
            );
            return;
        };
    }

    while (self.context.running.load(.seq_cst)) {
        io.sleep(.fromMilliseconds(100), .awake) catch |err| {
            self.context.resources.logger.err("# supervisor sleep failed: {any}", .{err});
            return;
        };
    }
}

pub fn acceptConnections(self: *Server) std.Io.Cancelable!void {
    const io = runtime_io.get();
    var slots: std.Io.Semaphore = .{ .permits = self.context.config.max_clients };
    var connections: std.Io.Group = .init;
    defer connections.cancel(io);

    while (self.context.running.load(.seq_cst)) {
        try slots.wait(io);
        const incoming = self.transport.accept() catch |err| {
            slots.post(io);
            if (err == error.Canceled) return error.Canceled;
            if (err == error.ConnectionAborted) continue;
            self.context.resources.logger.err("# accept failed: {any}", .{err});
            self.context.running.store(false, .seq_cst);
            return;
        };

        connections.concurrent(io, serve, .{ self, incoming, &slots }) catch |err| {
            var stream = incoming.stream;
            stream.close();
            slots.post(io);
            if (err == error.Canceled) return error.Canceled;
            self.context.resources.logger.err("# failed to start connection task: {any}", .{err});
        };
    }
}

fn serve(self: *Server, incoming: StreamServer.Connection, slots: *std.Io.Semaphore) std.Io.Cancelable!void {
    const io = runtime_io.get();
    defer slots.post(io);
    var accepted = incoming;
    defer accepted.stream.close();

    access.verify(self.context.config, self.context.resources.logger, accepted.address) catch return;

    self.transport.upgrade(&accepted.stream) catch |err| {
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

pub fn deinit(self: *Server) void {
    self.transport.deinit();
}
