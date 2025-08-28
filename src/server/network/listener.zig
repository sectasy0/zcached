const std = @import("std");

// Core utilities
const consts = @import("consts.zig");
const utils = @import("../utils.zig");
const Logger = @import("../logger.zig");

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

// Storage / memory
const Memory = @import("../storage/memory.zig");

// Internal modules
const Warden = @import("./warden.zig");

const Listener = @This();

server: *StreamServer,

context: Context,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, server: *StreamServer, context: Context) Listener {
    return .{
        .allocator = allocator,
        .server = server,
        .context = context,
    };
}

pub fn listen(self: *Listener, worker: *Worker) void {
    worker.poll_fds[0] = .{
        .revents = 0,
        .fd = self.server.sockfd.?,
        .events = std.posix.POLL.IN,
    };

    var warden = Warden.init(worker.allocator, self.context);

    while (self.context.running.*.load(.seq_cst)) {
        _ = std.posix.poll(worker.poll_fds[warden.start..worker.connections], 1000) catch |err| {
            self.context.resources.logger.err(
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
                const incoming = self.server.accept() catch |err| {
                    // "WouldBlock" is not an error, it just means that there are no incoming connections at the moment.
                    // We can safely ignore it and continue listening.
                    if (err == error.WouldBlock) continue;

                    self.context.resources.logger.err(
                        "# accept() failed with: {?}\n",
                        .{err},
                    );

                    continue;
                };
                const handle_result = warden.setupConnection(worker, incoming);
                if (handle_result != .err) continue;

                const err = handle_result.err.etype;
                var connection = handle_result.err.fd;
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
                        if (connection) |_| connection.?.close();
                        continue;
                    },
                    else => continue,
                }
            }

            // file descriptor is ready for reading.
            if (pollfd.revents & (std.posix.POLL.IN | std.posix.POLL.HUP) != 0) {
                const connection = worker.states.getPtr(pollfd.fd) orelse continue;
                warden.dispatch(worker, connection);
                continue;
            }

            // file descriptor is ready for writing.
            if (pollfd.revents & std.posix.POLL.OUT != 0) {
                const connection = worker.states.getPtr(pollfd.fd) orelse continue;
                // event returned for writing, so we can send data to the client.
                warden.handleOutgoing(worker, connection);
                continue;
            }

            // treat everything else as error/disconnect
            const connection = worker.states.getPtr(pollfd.fd) orelse continue;
            warden.teardownConnection(worker, connection);
        }
    }
}
