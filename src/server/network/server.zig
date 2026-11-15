const std = @import("std");
const runtime_io = @import("runtime_io");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

const Listener = @import("listener.zig");
const StreamServer = @import("stream_server.zig");
const Context = @import("../context.zig");

const Server = @This();

server: StreamServer,

context: Context,

listeners: []Listener,

allocator: std.mem.Allocator,

pub fn init(allocator: Allocator, context: Context) !Server {
    if (context.config.workers == 0 or context.config.max_clients == 0) return error.InvalidWorkerConfig;

    if (context.config.tls.enabled and build_options.tls_enabled) {
        context.resources.logger.info("# zcached is running with TLS enabled", .{});
    }

    var server = try StreamServer.init(.{
        .reuse_address = true,
        .tls = context.config.tls,
    });
    errdefer server.deinit();
    return .{
        .server = server,
        .context = context,
        .listeners = try allocator.alloc(Listener, context.config.workers),
        .allocator = allocator,
    };
}

pub fn run(self: *Server) void {
    self.context.resources.logger.info("# starting zcached server on tcp://{any} | Workers {}", .{
        self.context.config.address,
        self.context.config.workers,
    });
    self.server.listen(self.context.config.getAddress()) catch |err| {
        self.context.resources.logger.err(
            "# failed to run server listener: {any}",
            .{err},
        );
        return;
    };

    const io = runtime_io.get();
    var workers: std.Io.Group = .init;
    defer workers.cancel(io);

    for (self.listeners) |*listener| {
        listener.* = Listener.init(self.allocator, &self.server, self.context);
        workers.concurrent(io, Listener.listen, .{listener}) catch |err| {
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

pub fn deinit(self: *Server) void {
    self.server.deinit();
    self.allocator.free(self.listeners);
}
