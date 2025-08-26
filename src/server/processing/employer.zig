// Standard library
const std = @import("std");
const build_options = @import("build_options");
const Allocator = std.mem.Allocator;

// Network modules
const Listener = @import("../network/listener.zig");
const StreamServer = @import("../network/stream_server.zig");

// Logging and configuration
const Config = @import("../config.zig");
const Logger = @import("../logger.zig");
const utils = @import("../utils.zig");

// Storage and processing
const Memory = @import("../storage/memory.zig");
const Worker = @import("../processing/worker.zig");

const Employer = @This();

const AllocT = std.heap.GeneralPurposeAllocator(.{});

server: StreamServer,

context: Context,

workers: []Worker,
threads: []std.Thread,

allocators: []AllocT,

allocator: std.mem.Allocator,

/// `Context` holds data needed by zcached components.
///
/// - `resources` – runtime resources
/// - `config` – zcached configuration struct
pub const Context = struct {
    /// Runtime resources used by functions.
    pub const Resources = struct {
        memory: *Memory,
        logger: *Logger,
    };

    resources: Resources,
    config: *Config,

    // Flag indicating whether the server is runnin'
    quantum_flow: *std.atomic.Value(bool),
};

pub fn init(allocator: Allocator, context: Context) !Employer {
    std.debug.assert(context.config.workers > 0);

    if (context.config.tls.enabled and build_options.tls_enabled) {
        context.resources.logger.log(.Info, "# zcached is running with TLS enabled", .{});
    }

    return .{
        .server = try StreamServer.init(.{
            .reuse_address = true,
            .reuse_port = true,
            .tls = context.config.tls,
            .force_nonblocking = true,
        }),
        .context = context,
        .workers = try allocator.alloc(Worker, context.config.workers),
        .threads = try allocator.alloc(std.Thread, context.config.workers),
        .allocators = try allocator.alloc(AllocT, context.config.workers),
        .allocator = allocator,
    };
}

pub fn supervise(self: *Employer) void {
    self.server.listen(self.context.config.getAddress()) catch |err| {
        self.context.resources.logger.log(
            .Error,
            "# failed to run server listener: {?}",
            .{err},
        );
    };

    if (self.server.sockfd == null) {
        const err = error.AddressNotAvailable;

        // temporary set `sout` to true to force stdout print.
        const prev_sout = self.context.resources.logger.sout;
        self.context.resources.logger.sout = true;

        self.context.resources.logger.log(
            .Error,
            "# failed to run server listener: {?}",
            .{err},
        );
        self.context.resources.logger.sout = prev_sout;
        return;
    }

    var listener = Listener.init(
        self.allocator,
        &self.server,
        self.context,
    );
    const fds_size = self.context.config.max_clients;

    for (0..self.context.config.workers) |i| {
        // every thread have own allocator.
        self.allocators[i] = .init;
        const allocator = self.allocators[i].allocator();

        // + 1 becouse first index is always listener fd
        self.workers[i] = Worker.init(allocator, fds_size + 1) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# failed to create worker: {?}",
                .{err},
            );
            return;
        };

        errdefer self.workers[i].deinit();

        self.threads[i] = std.Thread.spawn(
            .{},
            delegate,
            .{ &self.workers[i], &listener },
        ) catch |err| {
            self.context.resources.logger.log(
                .Error,
                "# failed to swpan std.Thread: {?}",
                .{err},
            );
            return;
        };
    }

    self.context.resources.logger.flush();

    for (0..self.context.config.workers) |i| {
        self.threads[i].join();
    }
}

fn delegate(worker: *Worker, listener: *Listener) void {
    listener.listen(worker);
}

pub fn deinit(self: *Employer) void {
    for (self.workers) |*worker| worker.deinit();
    for (self.allocators) |*gpa| _ = gpa.deinit();

    self.allocator.free(self.workers);
    self.allocator.free(self.threads);
    self.allocator.free(self.allocators);
}
