//! Supervises worker threads and serves framed client requests over TCP.
const std = @import("std");
const runtime_io = @import("runtime_io");
const build_options = @import("build_options");
const access = @import("../middleware/access.zig");
const Connection = @import("connection.zig");
const StreamServer = @import("stream_server.zig");
const Context = @import("../context.zig");
const Processor = @import("../processing/requests.zig").Processor;

/// Current server type, used by lifecycle and worker methods.
const Server = @This();

/// Listening transport, including its listener and optional TLS context.
transport: StreamServer,
/// Shared application configuration, resources, and shutdown state.
context: Context,
/// Allocator used for workers, connections, and request processors.
allocator: std.mem.Allocator,

/// Validates worker limits and initializes the TCP/TLS transport.
pub fn init(allocator: std.mem.Allocator, io: std.Io, context: Context) !Server {
    if (context.config.workers == 0 or context.config.max_clients == 0) return error.InvalidWorkerConfig;

    if (context.config.tls.enabled and build_options.tls_enabled) {
        context.resources.logger.info("# zcached is running with TLS enabled", .{});
    }

    return .{
        .transport = try StreamServer.init(io, .{
            .reuse_address = true,
            .tls = context.config.tls,
        }),
        .context = context,
        .allocator = allocator,
    };
}

/// Starts the listener and worker runtimes, then joins started workers on shutdown.
pub fn run(self: *Server, io: std.Io) void {
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

    const workers = self.allocator.alloc(runtime_io.Worker, self.context.config.workers) catch |err| {
        self.context.resources.logger.err("# failed to allocate server workers: {any}", .{err});
        return;
    };
    defer self.allocator.free(workers);
    var started: usize = 0;
    defer {
        self.context.running.store(false, .seq_cst);
        for (workers[0..started]) |*worker| worker.join();
    }

    for (workers) |*worker| {
        worker.* = .{};
        worker.start(io, self.allocator, runWorker, .{self}) catch |err| {
            self.context.resources.logger.err(
                "# failed to start server worker runtime: {any}",
                .{err},
            );
            return;
        };
        started += 1;
    }

    while (self.context.running.load(.seq_cst)) {
        io.sleep(.fromMilliseconds(100), .awake) catch |err| {
            self.context.resources.logger.err("# supervisor sleep failed: {any}", .{err});
            return;
        };
    }
}

/// Runs the per-worker accept task and supervises it until shutdown.
fn runWorker(io: std.Io, self: *Server) void {
    var listener: std.Io.Group = .init;
    defer listener.cancel(io);
    listener.concurrent(io, acceptConnections, .{ self, io }) catch |err| {
        self.context.resources.logger.err("# failed to start worker listener: {any}", .{err});
        self.context.running.store(false, .seq_cst);
        return;
    };
    while (self.context.running.load(.seq_cst)) {
        io.sleep(.fromMilliseconds(100), .awake) catch |err| {
            self.context.resources.logger.err("# worker supervisor sleep failed: {any}", .{err});
            self.context.running.store(false, .seq_cst);
            return;
        };
    }
}

/// Accepts clients concurrently while limiting active connections with a semaphore.
pub fn acceptConnections(self: *Server, io: std.Io) std.Io.Cancelable!void {
    var slots: std.Io.Semaphore = .{ .permits = self.context.config.max_clients };
    var connections: std.Io.Group = .init;
    defer connections.cancel(io);

    while (self.context.running.load(.seq_cst)) {
        try slots.wait(io);
        const incoming = self.transport.accept(io) catch |err| {
            slots.post(io);
            if (err == error.Canceled) return error.Canceled;
            if (err == error.ConnectionAborted) continue;
            self.context.resources.logger.err("# accept failed: {any}", .{err});
            self.context.running.store(false, .seq_cst);
            return;
        };

        connections.concurrent(io, serve, .{ self, io, incoming, &slots }) catch |err| {
            var stream = incoming.stream;
            stream.close();
            slots.post(io);
            if (err == error.Canceled) return error.Canceled;
            self.context.resources.logger.err("# failed to start connection task: {any}", .{err});
        };
    }
}

/// Applies access and TLS checks, then processes framed requests until the client closes.
fn serve(self: *Server, io: std.Io, incoming: StreamServer.Connection, slots: *std.Io.Semaphore) std.Io.Cancelable!void {
    const deadline = @import("socket.zig").deadline;
    const network = self.context.config.network;
    defer slots.post(io);
    var accepted = incoming;
    defer accepted.stream.close();

    access.verify(self.context.config, self.context.resources.logger, accepted.address) catch return;

    self.transport.upgrade(&accepted.stream, deadline(io, network.idle_timeout_ms)) catch |err| {
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

    var request_deadline: std.Io.Timeout = .none;
    while (self.context.running.load(.seq_cst)) {
        const idle_deadline = deadline(io, network.idle_timeout_ms);
        const read_deadline = if (request_deadline == .none) idle_deadline else if (idle_deadline == .none or
            request_deadline.deadline.raw.nanoseconds <= idle_deadline.deadline.raw.nanoseconds) request_deadline else idle_deadline;
        const max_size = self.context.config.max_request_size;
        connection.readPendingTimed(if (max_size == 0) std.math.maxInt(usize) else max_size, read_deadline) catch |err| {
            switch (err) {
                error.IncompleteMessage => {
                    if (request_deadline == .none) request_deadline = deadline(io, network.request_timeout_ms);
                    continue;
                },
                error.Canceled => return error.Canceled,
                error.Timeout, error.ConnectionClosed, error.ConnectionResetByPeer, error.SocketUnconnected => return,
                else => {
                    self.context.resources.logger.err("# failed to read request: {any}", .{err});
                    return;
                },
            }
        };
        // A completed frame starts a new deadline only if this read also began the next frame.
        const ends_in_frame = connection.accumulator.items[connection.accumulator.items.len - 1] == @import("consts.zig").EXT_CHAR;
        request_deadline = if (ends_in_frame) .none else deadline(io, network.request_timeout_ms);
        while (true) {
            processor.deframe(&connection);
            if (connection.tx_accumulator.items.len == 0) break;
            connection.writePending() catch |err| {
                if (err == error.Canceled) return error.Canceled;
                self.context.resources.logger.err("# failed to write response: {any}", .{err});
                return;
            };
            if (network.max_pending_response_bytes == 0 or connection.accumulator.items.len == 0) break;
        }
    }
}

/// Closes the listener and releases any transport-owned TLS context.
pub fn deinit(self: *Server) void {
    self.transport.deinit();
}
